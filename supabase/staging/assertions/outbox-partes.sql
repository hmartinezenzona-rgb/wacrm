-- 348: one reply as several ordered WhatsApp messages through the outbox.
-- Covers: (1) one part is identical to cerebro_outbox_encolar; (2) three parts are enqueued atomically with
-- keys <base>:p1..p3 and a replay inserts nothing, a half conflict inserts nothing; (3) the claim is ordered
-- (part 2 waits for part 1, repeated claims never return two parts of one group, a retrying part blocks the
-- rest); (4) a part that fails for good cancels the rest and notifies "delivered in part (part X of N)";
-- (5) old ungrouped rows behave as before and are not blocked by a failed group; (6) failed_direct is now a
-- valid status; (7) shadow mode sends one joined message; (8) the flag exists and is off.
-- Needs 348 applied (staging-migracion.sh runs it after the migration). Rolls back on purpose.
\set ON_ERROR_STOP on
-- 365 diverts the four technical notification types into notification_digest_items; this assertion checks the
-- emitters' own rows, so the diversion trigger is off for this (rolled back) transaction. The digest has its own
-- assertion (notifications-digest.sql).
DO $digest_off$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zzz_notifications_to_digest' AND tgrelid = 'public.notifications'::regclass) THEN
    ALTER TABLE public.notifications DISABLE TRIGGER zzz_notifications_to_digest;
  END IF;
END $digest_off$;

DO $$
DECLARE
  v_conv uuid; v_acc uuid;
  v_fail text := '';
  v_run text := gen_random_uuid()::text;
  r1 record; r2 record; v_a uuid; v_b uuid; v_ids uuid[]; v_n int; v_i int; v_g uuid;
  v_txt text; v_estado text; v_solo uuid;
BEGIN
  SELECT c.id, c.account_id INTO v_conv, v_acc FROM conversations c LIMIT 1;
  IF v_conv IS NULL THEN RAISE EXCEPTION 'FAIL: no conversation on this database'; END IF;

  -- Deterministic mode and a clean queue: only the rows created below may be claimable.
  UPDATE cerebro_config SET valor = 'si' WHERE clave = 'outbox_activo';
  UPDATE message_outbox SET status = 'failed' WHERE status IN ('pending','retry_wait','sending');

  -- (1) one part == cerebro_outbox_encolar
  SELECT * INTO r1 FROM cerebro_outbox_encolar(v_conv, '+5990000001', '  Hola, un solo mensaje  ', NULL, 'a-' || v_run);
  SELECT * INTO r2 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000001', ARRAY['  Hola, un solo mensaje  '], NULL, 'b-' || v_run);
  IF r2.encolado IS DISTINCT FROM r1.encolado OR r2.motivo IS DISTINCT FROM r1.motivo
     OR r2.enviar_directo IS DISTINCT FROM r1.enviar_directo OR r2.partes IS DISTINCT FROM 1 THEN
    v_fail := v_fail || ' 1a:respuesta';
  END IF;
  IF (SELECT count(*) FROM message_outbox a, message_outbox b
       WHERE a.id = r1.outbox_id AND b.id = r2.outbox_id
         AND a.payload - 'to' = b.payload - 'to' AND a.payload = b.payload
         AND a.status = b.status AND a.message_type = b.message_type
         AND a.last_error IS NOT DISTINCT FROM b.last_error
         AND a.grupo_id IS NULL AND b.grupo_id IS NULL AND a.parte IS NULL AND b.parte IS NULL
         AND a.partes IS NULL AND b.partes IS NULL
         AND replace(a.idempotency_key, 'exec-a-', 'exec-X-') = replace(b.idempotency_key, 'exec-b-', 'exec-X-')) <> 1 THEN
    v_fail := v_fail || ' 1b:fila-distinta';
  END IF;
  -- same execution again: both say it was already enqueued, pointing at the same row
  SELECT * INTO r2 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000001', ARRAY['  Hola, un solo mensaje  '], NULL, 'a-' || v_run);
  IF r2.encolado OR r2.outbox_id IS DISTINCT FROM r1.outbox_id THEN v_fail := v_fail || ' 1c:replay'; END IF;
  -- empty arrays and blank parts
  SELECT * INTO r2 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000001', ARRAY['  ', ''], NULL, 'c-' || v_run);
  IF r2.encolado OR r2.partes <> 0 THEN v_fail := v_fail || ' 1d:vacio'; END IF;

  -- (2) three parts, atomic
  SELECT * INTO r1 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000002', ARRAY['uno','dos','tres'], NULL, 'g1-' || v_run);
  IF NOT r1.encolado OR r1.partes <> 3 OR r1.motivo <> 'encolado' THEN v_fail := v_fail || ' 2a:respuesta'; END IF;
  SELECT count(*), count(DISTINCT grupo_id), min(grupo_id::text)::uuid INTO v_n, v_i, v_g
    FROM message_outbox WHERE conversation_id = v_conv AND execution_id = 'g1-' || v_run;
  IF v_n <> 3 OR v_i <> 1 THEN v_fail := v_fail || ' 2b:filas=' || v_n; END IF;
  IF (SELECT array_agg(parte::text || '/' || partes::text || '=' || (payload ->> 'text') ORDER BY parte)
        FROM message_outbox WHERE grupo_id = v_g) IS DISTINCT FROM ARRAY['1/3=uno','2/3=dos','3/3=tres'] THEN
    v_fail := v_fail || ' 2c:orden';
  END IF;
  IF (SELECT count(*) FROM message_outbox WHERE grupo_id = v_g AND status = 'pending'
         AND idempotency_key ~ (':p[123]$')) <> 3
     OR r1.outbox_id IS DISTINCT FROM (SELECT id FROM message_outbox WHERE grupo_id = v_g AND parte = 1) THEN
    v_fail := v_fail || ' 2d:claves';
  END IF;
  SELECT * INTO r2 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000002', ARRAY['uno','dos','tres'], NULL, 'g1-' || v_run);
  IF r2.encolado OR (SELECT count(*) FROM message_outbox WHERE conversation_id = v_conv AND execution_id = 'g1-' || v_run) <> 3 THEN
    v_fail := v_fail || ' 2e:replay';
  END IF;
  -- half conflict: part 2's key already exists, so nothing of the new reply may remain
  v_txt := (SELECT split_part(idempotency_key, ':p1', 1) FROM message_outbox WHERE grupo_id = v_g AND parte = 1);
  DELETE FROM message_outbox WHERE grupo_id = v_g;
  INSERT INTO message_outbox (conversation_id, telefono_e164, payload, idempotency_key, execution_id, status)
  VALUES (v_conv, '+5990000002', '{}'::jsonb, v_txt || ':p2', 'g1-' || v_run, 'sent');
  BEGIN
    PERFORM * FROM cerebro_outbox_encolar_partes(v_conv, '+5990000002', ARRAY['uno','dos','tres'], NULL, 'g1-' || v_run);
    v_fail := v_fail || ' 2f:sin-excepcion';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF (SELECT count(*) FROM message_outbox WHERE execution_id = 'g1-' || v_run) <> 1 THEN
    v_fail := v_fail || ' 2g:parcial';
  END IF;
  DELETE FROM message_outbox WHERE execution_id = 'g1-' || v_run;

  -- (3) ordered claim (park the single rows made above so only the group is claimable)
  UPDATE message_outbox SET status = 'failed' WHERE status = 'pending';
  SELECT * INTO r1 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000003', ARRAY['uno','dos','tres'], NULL, 'g2-' || v_run);
  SELECT grupo_id INTO v_g FROM message_outbox WHERE id = r1.outbox_id;
  SELECT array_agg(c.id) INTO v_ids FROM cerebro_outbox_reclamar(10) c;
  IF v_ids IS DISTINCT FROM ARRAY[r1.outbox_id] THEN v_fail := v_fail || ' 3a:primero=' || coalesce(v_ids::text, 'null'); END IF;
  -- a second call (as a concurrent sender would) gets none of the group
  IF EXISTS (SELECT 1 FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g) THEN v_fail := v_fail || ' 3b:doble-reclamo'; END IF;
  -- part 1 fails once: it waits, and parts 2 and 3 still do not go
  PERFORM cerebro_outbox_resultado(r1.outbox_id, false, '-', 'prueba');
  UPDATE message_outbox SET next_attempt_at = now() + interval '1 minute' WHERE id = r1.outbox_id;
  IF EXISTS (SELECT 1 FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g) THEN v_fail := v_fail || ' 3c:salta-reintento'; END IF;
  UPDATE message_outbox SET next_attempt_at = now() - interval '1 second' WHERE id = r1.outbox_id;
  SELECT array_agg(c.id) INTO v_ids FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g;
  IF v_ids IS DISTINCT FROM ARRAY[r1.outbox_id] THEN v_fail := v_fail || ' 3d:reintento'; END IF;
  PERFORM cerebro_outbox_resultado(r1.outbox_id, true, '-', '-');
  SELECT array_agg(c.id ORDER BY c.parte) INTO v_ids FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g;
  IF v_ids IS DISTINCT FROM ARRAY[(SELECT id FROM message_outbox WHERE grupo_id = v_g AND parte = 2)] THEN
    v_fail := v_fail || ' 3e:segundo';
  END IF;
  PERFORM cerebro_outbox_resultado((SELECT id FROM message_outbox WHERE grupo_id = v_g AND parte = 2), true, '-', '-');
  SELECT array_agg(c.id) INTO v_ids FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g;
  IF v_ids IS DISTINCT FROM ARRAY[(SELECT id FROM message_outbox WHERE grupo_id = v_g AND parte = 3)] THEN
    v_fail := v_fail || ' 3f:tercero';
  END IF;
  PERFORM cerebro_outbox_resultado((SELECT id FROM message_outbox WHERE grupo_id = v_g AND parte = 3), true, '-', '-');
  IF (SELECT count(*) FROM message_outbox WHERE grupo_id = v_g AND status = 'sent') <> 3 THEN v_fail := v_fail || ' 3g:no-todo-enviado'; END IF;

  -- (4) a part fails for good: the rest is cancelled and the admin is told
  SELECT * INTO r1 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000004', ARRAY['uno','dos','tres'], NULL, 'g3-' || v_run);
  SELECT grupo_id INTO v_g FROM message_outbox WHERE id = r1.outbox_id;
  PERFORM c.id FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g;
  PERFORM cerebro_outbox_resultado(r1.outbox_id, true, '-', '-');
  v_b := (SELECT id FROM message_outbox WHERE grupo_id = v_g AND parte = 2);
  FOR v_i IN 1..4 LOOP
    UPDATE message_outbox SET next_attempt_at = now() - interval '1 second' WHERE id = v_b AND status = 'retry_wait';
    PERFORM c.id FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g;
    SELECT estado INTO v_estado FROM cerebro_outbox_resultado(v_b, false, '-', 'prueba: error');
  END LOOP;
  IF v_estado <> 'failed' THEN v_fail := v_fail || ' 4a:estado=' || v_estado; END IF;
  IF (SELECT status FROM message_outbox WHERE grupo_id = v_g AND parte = 3) <> 'cancelled'
     OR (SELECT status FROM message_outbox WHERE grupo_id = v_g AND parte = 1) <> 'sent'
     OR (SELECT last_error FROM message_outbox WHERE grupo_id = v_g AND parte = 3) NOT LIKE 'cancelado: la parte 2 de 3%' THEN
    v_fail := v_fail || ' 4b:cancelacion';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM notifications
                  WHERE account_id = (SELECT account_id FROM conversations WHERE id = v_conv)
                    AND type = 'mensaje_fallido'
                    AND body LIKE '%RESPUESTA ENTREGADA A MEDIAS: fallo la parte 2 de 3 (el cliente recibio 1 de 3 mensajes)%'
                    AND body LIKE '%Destino +5990000004%') THEN
    v_fail := v_fail || ' 4c:sin-aviso';
  END IF;
  -- nothing of that group is ever claimed again, even if a cancelled part is forced back to pending
  UPDATE message_outbox SET status = 'pending' WHERE grupo_id = v_g AND parte = 3;
  IF EXISTS (SELECT 1 FROM cerebro_outbox_reclamar(10) c WHERE c.grupo_id = v_g) THEN v_fail := v_fail || ' 4d:reclama-grupo-caido'; END IF;

  -- (5) old ungrouped rows: unchanged behaviour, not blocked by the failed group
  SELECT * INTO r1 FROM cerebro_outbox_encolar(v_conv, '+5990000005', 'mensaje suelto', NULL, 'u1-' || v_run);
  SELECT array_agg(c.id) INTO v_ids FROM cerebro_outbox_reclamar(10) c;
  IF v_ids IS DISTINCT FROM ARRAY[r1.outbox_id] THEN v_fail := v_fail || ' 5a:suelto'; END IF;
  FOR v_i IN 1..4 LOOP
    UPDATE message_outbox SET next_attempt_at = now() - interval '1 second' WHERE id = r1.outbox_id AND status = 'retry_wait';
    PERFORM c.id FROM cerebro_outbox_reclamar(10) c WHERE c.id = r1.outbox_id;
    SELECT estado INTO v_estado FROM cerebro_outbox_resultado(r1.outbox_id, false, '-', 'prueba suelta');
  END LOOP;
  IF v_estado <> 'failed' THEN v_fail := v_fail || ' 5b:estado=' || v_estado; END IF;
  IF EXISTS (SELECT 1 FROM notifications WHERE type = 'mensaje_fallido' AND body LIKE '%Destino +5990000005%' AND body LIKE '%A MEDIAS%') THEN
    v_fail := v_fail || ' 5c:aviso-de-grupo-en-suelto';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM notifications WHERE type = 'mensaje_fallido' AND body LIKE '%Destino +5990000005%'
                    AND body LIKE '%revisar si hay que contactar por otra via.') THEN
    v_fail := v_fail || ' 5d:aviso-cambiado';
  END IF;

  -- (6) a failed direct send (shadow row) is recorded instead of violating the CHECK
  INSERT INTO message_outbox (conversation_id, telefono_e164, payload, idempotency_key, execution_id, status)
  VALUES (v_conv, '+5990000006', '{}'::jsonb, 'prueba-directo-' || v_run, 'd-' || v_run, 'shadow') RETURNING id INTO v_solo;
  SELECT estado INTO v_estado FROM cerebro_outbox_resultado(v_solo, false, '-', 'directo fallo');
  IF v_estado <> 'failed_direct' THEN v_fail := v_fail || ' 6:directo=' || coalesce(v_estado, 'null'); END IF;

  -- (7) shadow mode: the Cerebro sends directly, so N parts become ONE joined message
  UPDATE cerebro_config SET valor = 'no' WHERE clave = 'outbox_activo';
  SELECT * INTO r1 FROM cerebro_outbox_encolar_partes(v_conv, '+5990000007', ARRAY['uno','dos','tres'], NULL, 's1-' || v_run);
  IF NOT r1.encolado OR NOT r1.enviar_directo OR r1.partes <> 1
     OR (SELECT count(*) FROM message_outbox WHERE execution_id = 's1-' || v_run) <> 1
     OR (SELECT payload ->> 'text' FROM message_outbox WHERE id = r1.outbox_id) <> E'uno\n\ndos\n\ntres'
     OR (SELECT grupo_id FROM message_outbox WHERE id = r1.outbox_id) IS NOT NULL THEN
    v_fail := v_fail || ' 7:shadow';
  END IF;
  UPDATE cerebro_config SET valor = 'si' WHERE clave = 'outbox_activo';

  -- (8) flag
  IF (SELECT valor FROM cerebro_config WHERE clave = 'opt_partir_respuesta') IS DISTINCT FROM 'no' THEN
    v_fail := v_fail || ' 8:flag';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
