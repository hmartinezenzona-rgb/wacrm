-- =====================================================================
-- Assertion for migration 187 (the operations panel reads the bot's current quote).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and on production
-- (it only uses conversations, messages and the 171 cerebro_cotizacion trigger, present in both).
-- The caller is simulated through request.jwt.claims, the way auth.uid() reads it.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_cot(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900187' || p_tag, 'test187' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.bot_dice(p_conv uuid, p_texto text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated)
  VALUES (p_conv, 'agent', 'text', p_texto, true);
$$;

DO $$
DECLARE
  v_conv uuid; v_member uuid; v_q record; v_n int; v_ok boolean;
BEGIN
  v_conv := pg_temp.conv_cot('01');
  SELECT p.user_id INTO v_member FROM profiles p JOIN conversations c ON c.account_id = p.account_id
   WHERE c.id = v_conv AND p.account_role IS NOT NULL LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_member, 'role', 'authenticated')::text, true);

  -- 1. No quote yet: no row.
  SELECT count(*) INTO v_n FROM crm_cotizacion_de_conversacion(v_conv);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: no quote must give no row, got %', v_n; END IF;

  -- 2. A CUP inverse quote: 5,000 GYD -> 15,000 CUP.
  PERFORM pg_temp.bot_dice(v_conv, 'Buenos días, le atiende el asistente virtual de *Remesas Ya*.' || chr(10)
    || 'Para que lleguen *15,000 CUP* necesita depositar *5,000 GYD*.' || chr(10) || 'Anotada la tarjeta *9800 9087 1234 1234*.');
  SELECT * INTO v_q FROM crm_cotizacion_de_conversacion(v_conv);
  IF v_q.gyd IS DISTINCT FROM 5000 OR v_q.destino_monto IS DISTINCT FROM 15000 OR v_q.destino_moneda IS DISTINCT FROM 'CUP' THEN
    RAISE EXCEPTION 'case 2: expected 5000 GYD -> 15000 CUP, got % -> % %', v_q.gyd, v_q.destino_monto, v_q.destino_moneda;
  END IF;

  -- 3. A newer USD quote replaces it: 26,000 GYD -> 100 USD.
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *100 USD* por Zelle, Clásica o Tropical necesita depositar *26,000 GYD* (en efectivo la tasa es otra).');
  SELECT * INTO v_q FROM crm_cotizacion_de_conversacion(v_conv);
  IF v_q.gyd IS DISTINCT FROM 26000 OR v_q.destino_monto IS DISTINCT FROM 100 OR v_q.destino_moneda IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case 3: expected 26000 GYD -> 100 USD, got % -> % %', v_q.gyd, v_q.destino_monto, v_q.destino_moneda;
  END IF;

  -- 4. A forward quote: "Por *30,000 GYD* llegan *90,000 CUP* a Cuba."
  PERFORM pg_temp.bot_dice(v_conv, 'Por *30,000 GYD* llegan *90,000 CUP* a Cuba.');
  SELECT * INTO v_q FROM crm_cotizacion_de_conversacion(v_conv);
  IF v_q.gyd IS DISTINCT FROM 30000 OR v_q.destino_monto IS DISTINCT FROM 90000 OR v_q.destino_moneda IS DISTINCT FROM 'CUP' THEN
    RAISE EXCEPTION 'case 4: expected 30000 GYD -> 90000 CUP, got % -> % %', v_q.gyd, v_q.destino_monto, v_q.destino_moneda;
  END IF;

  -- 5. Read-only: nothing on any operation or target changed for this conversation.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio WHERE conversation_id = v_conv) THEN
    RAISE EXCEPTION 'case 5: reading the quote must not fix a target'; END IF;

  -- 6. A quote older than the window is not shown.
  UPDATE cerebro_cotizacion SET cotizado_en = now() - interval '7 hours' WHERE conversation_id = v_conv;
  SELECT count(*) INTO v_n FROM crm_cotizacion_de_conversacion(v_conv);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 6: a quote older than the window must not be shown'; END IF;

  -- 7. Someone outside the account gets 42501.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN
    PERFORM * FROM crm_cotizacion_de_conversacion(v_conv);
  EXCEPTION WHEN insufficient_privilege THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7: a non-member must get insufficient_privilege'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
