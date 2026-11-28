-- ROLLBACK 183 (staging): 179's deal-notes writer.

CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_deal uuid;
BEGIN
  IF p_op IS NOT NULL THEN
    SELECT deal_id INTO v_deal FROM remittance_operations WHERE id = p_op;
  END IF;
  IF v_deal IS NOT NULL THEN
    UPDATE deals SET notes = COALESCE(notes, '') || E'\n---\n' || p_bloque, updated_at = now() WHERE id = v_deal;
    RETURN v_deal;
  END IF;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, '78220927-0745-45a8-ba08-a1b33734dbf1',
         '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109', 'Remesa +' || c.phone, 0, 'GYD', p_bloque, 'open'
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv
  RETURNING id INTO v_deal;
  RETURN v_deal;
END $$;
