-- Fixture PRUEBA para el panel de STAGING. Solo staging.
-- Sin BEGIN/COMMIT: ejecutar con psql -1 (una transaccion) y con TODAS las variables (vacias si no aplican):
--   -v n=0007 -v nombre='envio mixto' -v svc1=remesa -v ruta1=cuban_card -v monto1=24400 -v estado1=ready_to_transfer
--   -v moneda_dest=USD -v monto_dest=93 -v con_beneficiario=1 -v deposito=24400 -v deposito_consumido=1
--   -v objetivo=1 -v svc2= -v monto2= -v ultimo_mensaje='ya te envie el deposito'
-- n: 4 digitos; telefono 5990253nnnn (el fixture aborta si ya existe). Los valores se pasan por set_config
-- porque psql no sustituye variables dentro de $$...$$.
-- Filas creadas: contacto, conversacion (ai_autoreply_disabled), mensaje cliente, 1 o 2 operaciones,
-- beneficiario completo (tarjeta + telefono), deposito consumido opcional y objetivo de envio opcional.
-- Todo lleva prefijo PRUEBA y el telefono 5990253 para que limpieza.sql lo encuentre.

SELECT
       set_config('pr.n', :'n', true),
       set_config('pr.nombre', :'nombre', true),
       set_config('pr.svc1', :'svc1', true),
       set_config('pr.ruta1', :'ruta1', true),
       set_config('pr.monto1', :'monto1', true),
       set_config('pr.estado1', :'estado1', true),
       set_config('pr.moneda_dest', :'moneda_dest', true),
       set_config('pr.monto_dest', :'monto_dest', true),
       set_config('pr.con_beneficiario', :'con_beneficiario', true),
       set_config('pr.deposito', :'deposito', true),
       set_config('pr.deposito_consumido', :'deposito_consumido', true),
       set_config('pr.objetivo', :'objetivo', true),
       set_config('pr.svc2', :'svc2', true),
       set_config('pr.monto2', :'monto2', true),
       set_config('pr.ultimo_mensaje', :'ultimo_mensaje', true)
\g /dev/null

DO $fx$
DECLARE
  v_n      text := current_setting('pr.n');
  v_phone  text := '5990253' || lpad(current_setting('pr.n'), 4, '0');
  v_nombre text := 'PRUEBA ' || current_setting('pr.nombre');
  v_ben_ph text := '5350000000';
  v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid; v_op uuid; v_op2 uuid;
  v_dep  text; v_svc2 text := NULLIF(current_setting('pr.svc2'), '');
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION 'fixture: no account with whatsapp_config'; END IF;
  IF EXISTS (SELECT 1 FROM contacts WHERE account_id = v_acc AND phone = v_phone) THEN
    RAISE EXCEPTION 'fixture: phone % already used, pick another n', v_phone; END IF;

  INSERT INTO contacts (user_id, phone, name, account_id)
  VALUES (v_user, v_phone, v_nombre, v_acc) RETURNING id INTO v_ct;

  INSERT INTO conversations (user_id, contact_id, account_id, status, ai_autoreply_disabled,
                             last_message_text, last_message_at)
  VALUES (v_user, v_ct, v_acc, 'open', true, current_setting('pr.ultimo_mensaje'), now())
  RETURNING id INTO v_cv;

  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, message_id)
  VALUES (v_cv, 'customer', 'text', current_setting('pr.ultimo_mensaje'), 'delivered', 'PRUEBA-' || v_n);

  -- operation 1 (the anchor: remesa or recarga)
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, destination_currency, quoted_destination_amount)
  VALUES (v_acc, v_cv, v_ct, current_setting('pr.estado1'), current_setting('pr.svc1'),
          NULLIF(current_setting('pr.ruta1'), ''), 'GYD', current_setting('pr.monto1')::numeric,
          NULLIF(current_setting('pr.moneda_dest'), ''), NULLIF(current_setting('pr.monto_dest'), '')::numeric)
  RETURNING id INTO v_op;

  IF current_setting('pr.con_beneficiario') = '1' THEN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, delivery_method,
                                          amount, currency, position, block_index, source, status)
    VALUES (v_op, current_setting('pr.ruta1'), 'PRUEBA Beneficiario',
            CASE WHEN current_setting('pr.ruta1') = 'cuban_card' THEN '9200000000000000' END, v_ben_ph,
            current_setting('pr.ruta1'), NULLIF(current_setting('pr.monto_dest'), '')::numeric,
            NULLIF(current_setting('pr.moneda_dest'), ''), 1, 1, 'manual', 'vigente');
  END IF;

  -- operation 2 (optional, e.g. recarga of a mixed send): no destination, phone beneficiary
  IF v_svc2 IS NOT NULL THEN
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type,
                                       source_currency, quoted_source_amount)
    VALUES (v_acc, v_cv, v_ct, current_setting('pr.estado1'), v_svc2, 'GYD',
            current_setting('pr.monto2')::numeric)
    RETURNING id INTO v_op2;
    IF current_setting('pr.con_beneficiario') = '1' THEN
      INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, position, block_index,
                                            source, status)
      VALUES (v_op2, v_svc2, 'PRUEBA Beneficiario', v_ben_ph, 1, 1, 'manual', 'vigente');
    END IF;
  END IF;

  -- consumed (or free) deposit; asunto carries the phone so limpieza.sql finds it
  IF current_setting('pr.deposito')::numeric > 0 THEN
    SELECT (COALESCE((SELECT max(trans_id::numeric) FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$'),
                     20000000000000) + 1)::bigint::text INTO v_dep;
    INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, operation_id, consumido_en)
    VALUES (v_dep, current_setting('pr.deposito')::numeric, 'GYD', 'PRUEBA Titular',
            'PRUEBA ' || v_phone || ' ' || current_setting('pr.nombre'), now(),
            CASE WHEN current_setting('pr.deposito_consumido') = '1' THEN v_op END,
            CASE WHEN current_setting('pr.deposito_consumido') = '1' THEN now() END);
  END IF;

  IF current_setting('pr.objetivo') = '1' THEN
    INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, operation_id)
    VALUES (v_cv, current_setting('pr.monto1')::numeric, 'GYD', v_op);
  END IF;

  RAISE NOTICE 'fixture ok: telefono=% contacto=% conversacion=% operacion=% operacion2=% deposito=%',
    v_phone, v_ct, v_cv, v_op, v_op2, v_dep;
END
$fx$;
