-- =====================================================================
-- Assertion for migration 211 (a mentioned recharge needs a promo and no Zelle). Self-reverting: one DO block that
-- ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Production 2026-10-02 (Yilian) and 2026-09-23 (Yusmila): the customer asked about a recharge, there was no promo,
-- and a later deposit for something else (a 320 USD Zelle, a cash delivery) was filed as a recharge, because the
-- typed-text rule of cerebro_recarga_en_curso only looked for "recarga" and a pending card.
-- =====================================================================
DO $$
DECLARE
  v_hoy  date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
  c_verif constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';  -- "Por verificar"
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990021101', 'test211') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (v_conv, 'customer', 'text', 'Tiene promocion de recarga de telefono', now() - interval '30 minutes');

  -- 1. No promo at all: asking about a recharge is not a recharge in progress, and the deposit is not filed as one.
  IF cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 1: a recharge in progress with no promo'; END IF;
  PERFORM cerebro_registrar_deposito(v_conv, 83200, 'GYD', c_verif, NULL, NULL);
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'recarga') THEN
    RAISE EXCEPTION 'case 1: the deposit was filed as a recharge with no promo'; END IF;
  UPDATE remittance_operations SET status = 'cancelled' WHERE conversation_id = v_conv;
  -- (closing an operation restarts the typed window: the question is asked again after it)
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (v_conv, 'customer', 'text', 'Tiene promocion de recarga de telefono', clock_timestamp() + interval '1 second');

  -- 2. A promo running: the same question makes it a recharge in progress (behaviour kept).
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-211'), 'confirmada');
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 2: a promo running must keep the typed rule'; END IF;

  -- 3. A promo running, but the customer then typed Zelle: a recharge never goes by Zelle.
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (v_conv, 'customer', 'text', '320 Zelle', clock_timestamp() + interval '2 seconds');
  IF cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 3: Zelle typed must turn the recharge rule off'; END IF;
  DELETE FROM messages WHERE conversation_id = v_conv AND content_text = '320 Zelle';

  -- 4. A promo running and Zelle data pending in the partial beneficiary: not a recharge either.
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_cuenta) VALUES (v_conv, '7868613281')
  ON CONFLICT (conversation_id) DO UPDATE SET zelle_cuenta = excluded.zelle_cuenta;
  IF cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 4: pending Zelle data must turn the recharge rule off'; END IF;
  DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv;

  -- 5. An open recharge stays a recharge in progress even with no promo (the agent or a person opened it).
  UPDATE promo_etecsa SET estado = 'descartada' WHERE huella = md5('assert-vigente-211');
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'recarga', 'GYD', 0);
  IF NOT cerebro_recarga_en_curso(v_conv) THEN RAISE EXCEPTION 'case 5: an open recharge must stay in progress'; END IF;

  RAISE EXCEPTION 'ALL PASS';
END $$;
