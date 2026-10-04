-- =====================================================================
-- 204 — A recharge asked for by AUDIO (staging first)
--
-- odd/tasks/panel-other-services.md. cerebro_recarga_en_curso reads TYPED text only (voice-note transcriptions are not
-- stored), so a recharge asked for by voice had its deposit filed as a remesa. The agent understands the audio and
-- already quotes the recharge: its tool now calls crm_registrar_numeros_recarga(conv, text, p_abrir => true), which
-- opens the recharge without a typed keyword and even before any number; and an open recharge counts as "recharge in
-- progress", so cerebro_registrar_deposito's deposit lands on it. Calls with two arguments (the DB's own callers)
-- behave as in 202. Signature changes: dropped and recreated.
--
-- Guarded by supabase/staging/assertions/recarga-by-audio.sql.
-- ROLLBACK: ROLLBACK-204-recarga-by-audio.sql
-- =====================================================================
DROP FUNCTION public.crm_registrar_numeros_recarga(uuid, text);

CREATE OR REPLACE FUNCTION public.cerebro_recarga_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202) The customer asked for a recharge in that window (recarga/etecsa/cubacel) and no card is pending: the
  -- same rule cerebro_registrar_deposito used inline since 160 to file a deposit as a recharge.
  SELECT (coalesce(cerebro_textos_cliente_recientes(p_conv) ~* '(recarga|etecsa|cubacel)', false)
          AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                           WHERE bp.conversation_id = p_conv AND COALESCE(bp.tarjeta, '') <> ''))
      -- (204) or a recharge is already open (the agent opened it: asked for by audio)
      OR EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'recarga'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$;

CREATE OR REPLACE FUNCTION public.crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (201) The Cuban mobile numbers found in p_texto go to the conversation's open recharge, one row per number
-- (beneficiary_type 'recarga'), without repeats; the panel's beneficiary lock wins. Returns what was saved and how many
-- numbers the recharge still needs (cerebro_recarga_unidades of its deposit).
DECLARE
  v_op     record;
  v_m      text[];
  v_num    text;
  v_added  int := 0;
  v_have   int;
  v_need   int;
  v_pos    int;
  v_block  int;
BEGIN
  SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC LIMIT 1
   FOR UPDATE;
  IF v_op.id IS NULL THEN
    -- (202) The customer asked for a recharge: it opens now (collecting its numbers), so the panel shows it before
    -- the deposit; the deposit lands on it (cerebro_registrar_deposito).
    -- (204) p_abrir: the agent understood a recharge (e.g. asked for by AUDIO, which the typed-text rule cannot see).
    IF NOT (p_abrir OR cerebro_recarga_en_curso(p_conv)) THEN
      RETURN 'sin recarga en curso: no se guarda ningun numero de recarga';
    END IF;
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
    SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'recarga', 'GYD', 0
      FROM conversations v WHERE v.id = p_conv
    RETURNING id, account_id, quoted_source_amount, admin_locked_fields INTO v_op;
  END IF;
  IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
    RETURN 'los numeros de esta recarga los gestiona una persona desde el panel: no se cambian';
  END IF;

  FOR v_m IN SELECT regexp_matches(coalesce(p_texto, ''),
                                   '(?<![0-9])(?:\+?53[ -]?)?([56][0-9]{3})[ .-]?([0-9]{4})(?![0-9])', 'g') LOOP
    v_num := v_m[1] || v_m[2];
    CONTINUE WHEN EXISTS (SELECT 1 FROM remittance_beneficiaries b
                           WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.phone = v_num);
    SELECT coalesce(max(position), 0) + 1 INTO v_pos FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = v_op.id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
    VALUES (v_op.id, 'recarga', v_num, v_pos, v_block, 'reparto_auto', 'vigente');
    v_added := v_added + 1;
  END LOOP;

  IF v_added > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'recarga_numbers', 'automation_recharge_numbers_registered',
            wacrm_current_actor(), NULL, jsonb_build_object('added', v_added, 'texto', left(coalesce(p_texto, ''), 300)));
  END IF;

  SELECT count(*) INTO v_have FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga';
  v_need := cerebro_recarga_unidades(v_op.quoted_source_amount);
  RETURN 'guardados ' || v_added || ' numero(s) de recarga nuevos; la recarga tiene ' || v_have || '.'
         || CASE WHEN coalesce(v_need, 0) = 0 THEN ''
                 WHEN v_have >= v_need THEN ' Numeros completos (' || v_have || ' de ' || v_need || ').'
                 ELSE ' FALTA ' || (v_need - v_have) || ' numero(s) de recarga (son ' || v_need || ' recargas, un numero por recarga). Pideselo al cliente.' END;
END $function$;

REVOKE ALL ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean) TO service_role;
