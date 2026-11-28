-- reset-test-contact.sql — STAGING ONLY. Wipes every trace of one WhatsApp
-- test number so the next message starts a brand-new customer: contact,
-- conversations, messages, bot memory, operations (+ beneficiaries, proofs,
-- calculator entries), deals, receipts, outbox, session events, cerebro_*
-- audit rows, notifications.
--
-- Usage (never point it at production):
--   set -a; source .env.staging; set +a
--   docker run --rm -i postgres:17-alpine psql "$CRM_STAGING_DATABASE_URL" \
--     -v ON_ERROR_STOP=1 -v phone=529622896918 < supabase/staging/reset-test-contact.sql
--
-- `phone` is digits only; it matches every phone column after stripping
-- non-digits. A Mexican number is also matched in its WhatsApp form with the
-- trunk `1` (52 + 10 digits <-> 521 + 10 digits): the webhook stores the
-- trunk form first and send-message later rewrites it, so both show up. Completed calculator entries are append-only (guard 149), so
-- they are voided first (void_shape_chk needs voided_at) and then deleted.

\if :{?phone}
\else
  \echo 'usage: -v phone=<digits>'
  \quit
\endif

BEGIN;
SELECT set_config('reset.phone', :'phone', true);

DO $$
DECLARE
  v_phone text := current_setting('reset.phone');
  v_phones text[];
  v_left  bigint := 0;
  v_n     bigint;
  r       record;
BEGIN
  IF v_phone !~ '^\d{8,15}$' THEN
    RAISE EXCEPTION 'reset-test-contact: phone must be 8-15 digits, got %', v_phone;
  END IF;
  v_phones := ARRAY[v_phone]
    || CASE WHEN v_phone ~ '^52\d{10}$' THEN ARRAY['521' || substr(v_phone, 3)]
            WHEN v_phone ~ '^521\d{10}$' THEN ARRAY['52' || substr(v_phone, 4)]
            ELSE ARRAY[]::text[] END;

  CREATE TEMP TABLE rt_ct   ON COMMIT DROP AS
    SELECT id FROM contacts WHERE regexp_replace(phone, '\D', '', 'g') = ANY (v_phones);
  CREATE TEMP TABLE rt_conv ON COMMIT DROP AS
    SELECT id FROM conversations WHERE contact_id IN (SELECT id FROM rt_ct);
  CREATE TEMP TABLE rt_ops  ON COMMIT DROP AS
    SELECT id FROM remittance_operations
     WHERE conversation_id IN (SELECT id FROM rt_conv) OR contact_id IN (SELECT id FROM rt_ct);

  RAISE NOTICE 'reset-test-contact: % contact(s), % conversation(s), % operation(s)',
    (SELECT count(*) FROM rt_ct), (SELECT count(*) FROM rt_conv), (SELECT count(*) FROM rt_ops);

  DELETE FROM cerebro_memoria WHERE session_id IN (SELECT id::text FROM rt_conv);
  UPDATE remittance_calculator_entries SET status = 'void', voided_at = now()
   WHERE operation_id IN (SELECT id FROM rt_ops) AND status = 'completed';
  -- (227) entries archived in a weekly cut are referenced by remittance_calculator_week_entries.
  DELETE FROM remittance_calculator_week_entries
   WHERE entry_id IN (SELECT id FROM remittance_calculator_entries WHERE operation_id IN (SELECT id FROM rt_ops));
  DELETE FROM remittance_calculator_entries WHERE operation_id IN (SELECT id FROM rt_ops);
  DELETE FROM tool_execution_log
   WHERE conversation_id::text IN (SELECT id::text FROM rt_conv)
      OR operation_id::text IN (SELECT id::text FROM rt_ops);
  DELETE FROM deals
   WHERE conversation_id IN (SELECT id FROM rt_conv) OR contact_id IN (SELECT id FROM rt_ct);
  DELETE FROM remittance_operations WHERE id IN (SELECT id FROM rt_ops);
  DELETE FROM message_outbox
   WHERE conversation_id::text IN (SELECT id::text FROM rt_conv)
      OR regexp_replace(telefono_e164, '\D', '', 'g') = ANY (v_phones);
  DELETE FROM session_events
   WHERE conversation_id::text IN (SELECT id::text FROM rt_conv)
      OR regexp_replace(contact_phone, '\D', '', 'g') = ANY (v_phones);
  DELETE FROM cerebro_ejecuciones          WHERE conversation_id::text IN (SELECT id::text FROM rt_conv);
  DELETE FROM cerebro_semantic_turn_audit  WHERE conversation_id::text IN (SELECT id::text FROM rt_conv);
  DELETE FROM cerebro_telemetria_turno     WHERE conversation_id::text IN (SELECT id::text FROM rt_conv);
  DELETE FROM comprobantes_hashes WHERE regexp_replace(cliente_whatsapp, '\D', '', 'g') = ANY (v_phones);
  -- Cascades to conversations, messages, notifications, tags, notes,
  -- cerebro_objetivo_envio and cerebro_ultima_cotizacion.
  DELETE FROM contacts WHERE id IN (SELECT id FROM rt_ct);

  -- Leftover scan: any public column that still points at this number.
  FOR r IN
    SELECT c.table_name t, c.column_name col
      FROM information_schema.columns c
      JOIN information_schema.tables tb
        ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
       AND tb.table_type = 'BASE TABLE'
     WHERE c.table_schema = 'public'
       AND c.column_name ~ '(phone|whatsapp|telefono|wa_id)'
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE regexp_replace(%I::text, ''\D'', '''', ''g'') = ANY ($1)',
                   r.t, r.col) INTO v_n USING v_phones;
    IF v_n > 0 THEN
      v_left := v_left + v_n;
      RAISE WARNING 'reset-test-contact: % row(s) left in %.%', v_n, r.t, r.col;
    END IF;
  END LOOP;

  IF v_left > 0 THEN
    RAISE EXCEPTION 'reset-test-contact: % row(s) still reference %; nothing was deleted', v_left, v_phone;
  END IF;
  RAISE NOTICE 'reset-test-contact: % is clean', array_to_string(v_phones, ' / ');
END $$;

COMMIT;
