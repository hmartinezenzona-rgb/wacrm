-- =====================================================================
-- Assertion for migration 366 (part 1): the bot's re-quote replaces the older quote.
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'; any failure RAISEs its own message.
-- Real case (conversation 29597f4b, 2026-11-12): 5,000 GYD quoted, then re-quoted at 10,000 GYD with
-- "Con *10,000 GYD* salen ..." and "los *10,000 GYD* quedan completos ..."; both were ignored.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_g numeric;
  t_5000   constant text := 'Por *5,000 GYD* llegan *18,000 CUP* a Cuba.';
  t_1509   constant text := 'Con *10,000 GYD* salen *36,000 CUP*: *18,000 CUP* para cada tarjeta.';
  t_1523   constant text := 'Sí, los *10,000 GYD* quedan completos en esa misma tarjeta: *36,000 CUP*.';
BEGIN
  -- Pure parser.
  IF cerebro_monto_cotizado(t_5000) IS DISTINCT FROM 5000 THEN RAISE EXCEPTION 'p1: the original quote must keep parsing, got %', cerebro_monto_cotizado(t_5000); END IF;
  IF cerebro_monto_cotizado(t_1509) IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 'p2: "Con X GYD salen" re-quote, got %', cerebro_monto_cotizado(t_1509); END IF;
  IF cerebro_monto_cotizado(t_1523) IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 'p3: "los X GYD quedan completos" re-quote, got %', cerebro_monto_cotizado(t_1523); END IF;
  IF cerebro_monto_cotizado('Con *10,000 GYD* le llegan *36,000 CUP* en total.') IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 'p4: "Con X GYD le llegan"'; END IF;
  RAISE NOTICE 'PASS parser: the two production re-quotes parse to 10,000';

  -- Negatives that must stay negatives (per-card share, minimums, rates, paging).
  IF cerebro_monto_cotizado('Por *15,000 GYD* llegan *45,000 CUP* a esa tarjeta.') IS NOT NULL THEN RAISE EXCEPTION 'n1: per-card share is not a quote'; END IF;
  IF cerebro_monto_cotizado('Por *15,000 GYD* llegan *45,000 CUP* a cada tarjeta.') IS NOT NULL THEN RAISE EXCEPTION 'n2: "a cada tarjeta" share is not a quote'; END IF;
  IF cerebro_monto_cotizado('Con *10,000 GYD* salen *36,000 CUP* a cada tarjeta.') IS NOT NULL THEN RAISE EXCEPTION 'n3: "a cada" share, new wording, is not a quote'; END IF;
  IF cerebro_monto_cotizado('El mínimo es de *5,000 GYD*; con *10,000 GYD* salen *36,000 CUP*.') IS NOT NULL THEN RAISE EXCEPTION 'n4: minimum notice is not a quote'; END IF;
  IF cerebro_monto_cotizado('La tasa es *3.6*: con *10,000 GYD* salen *36,000 CUP*.') IS NOT NULL THEN RAISE EXCEPTION 'n5: rate notice is not a quote'; END IF;
  IF cerebro_monto_cotizado('Con *10,000 GYD* salen *36,000 CUP*; con *20,000 GYD* salen *72,000 CUP*.') IS NOT NULL THEN RAISE EXCEPTION 'n6: two figures are ambiguous'; END IF;
  IF cerebro_monto_cotizado('Hoy no hay cambio especial.') IS NOT NULL THEN RAISE EXCEPTION 'n7: no figure, no quote'; END IF;
  RAISE NOTICE 'PASS negatives unchanged';

  -- Trigger level: 5,000 then the two re-quotes; the quote that governs the deposit check follows the last one.
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900366001', 'PRUEBA 366') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated) VALUES (v_conv, 'agent', 'text', t_5000, true);
  SELECT gyd INTO v_g FROM cerebro_cotizacion WHERE conversation_id = v_conv;
  IF v_g IS DISTINCT FROM 5000 THEN RAISE EXCEPTION 't1: first quote stored 5000, got %', v_g; END IF;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated) VALUES (v_conv, 'agent', 'text', t_1509, true);
  SELECT gyd INTO v_g FROM cerebro_cotizacion WHERE conversation_id = v_conv;
  IF v_g IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 't2: the re-quote must replace 5000, got %', v_g; END IF;
  UPDATE cerebro_cotizacion SET gyd = 5000 WHERE conversation_id = v_conv;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated) VALUES (v_conv, 'agent', 'text', t_1523, true);
  SELECT gyd INTO v_g FROM cerebro_cotizacion WHERE conversation_id = v_conv;
  IF v_g IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 't3: the confirmation re-quote must also be recorded, got %', v_g; END IF;
  RAISE NOTICE 'PASS trigger: quote follows the latest re-quote';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
