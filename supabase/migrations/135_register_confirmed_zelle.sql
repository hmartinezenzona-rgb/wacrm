-- =====================================================================
-- 135 — A Zelle account the bot confirmed but nobody stored is registered
--
-- 132 made the name the bot confirms ("*Nombre:* X / *Celular:* Y") reach the
-- panel, but only for an account that was already stored. The bot sometimes
-- confirms an account the deterministic extractor never read. Real cases since
-- August whose remesa was completed with NO beneficiary:
--   - 00ced244 Yamile Dominguez: the number on one line, the name on the next;
--   - 26b6e7bb Solution travel Svcs corp: a lower-case word in the name;
--   - 774cad3d Pencargo Trading: the data inside a block of instructions;
--   - 8d6d9758 Margarita gonzalez: "786 750 8534. Margarita gonzalez".
-- cerebro_aplicar_nombre_confirmado now also REGISTERS such an account, with
-- the same notes block as 'Registrar zelle auto', only when:
--   - the message has exactly one "*Nombre:*" block (repartos are left alone);
--   - the customer wrote the account and every word of the name (last 24 h);
--   - the beneficiary matcher (126/133) picks exactly ONE open remesa;
--   - that remesa has no current beneficiary at all and is not locked.
-- The name-correction behaviour of 132 is unchanged.
--
-- ROLLBACK: re-apply 132's function (ROLLBACK-135-register-confirmed-zelle.sql)
-- Guarded by supabase/staging/assertions/zelle-confirmed-name.sql (cases 8-11)
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_aplicar_nombre_confirmado(p_conversation_id uuid, p_texto text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n          integer;
  v_nombre     text;
  v_cuenta_raw text;
  v_cuenta     text;
  v_cliente    text;
  v_falta      boolean;
  v_op_id      uuid;
  v_deal_id    uuid;
  v_locked     boolean;
  v_actual     text;
  v_cta_guard  text;
  v_res        record;
  v_digitos    text;
BEGIN
  IF p_conversation_id IS NULL OR p_texto IS NULL THEN RETURN 'sin_datos'; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(p_texto, '\*Nombre:\*', 'g');
  IF v_n = 0 THEN RETURN 'sin_nombre'; END IF;
  IF v_n > 1 THEN RETURN 'varias_cuentas'; END IF;

  -- The name, clean: no emojis/flags/symbols, no word "Zelle", single spaces.
  v_nombre := (regexp_match(p_texto, '\*Nombre:\*[ \t]*([^\n]*)'))[1];
  v_nombre := regexp_replace(coalesce(v_nombre, ''), '[^[:alpha:][:digit:][:space:]&.,''()-]', ' ', 'g');
  v_nombre := regexp_replace(v_nombre, '\mzelle\M', ' ', 'gi');
  v_nombre := btrim(regexp_replace(v_nombre, '\s+', ' ', 'g'), ' ,.;:-');
  v_cuenta_raw := (regexp_match(p_texto, '\*(?:Celular|Cuenta Zelle|Cuenta|Correo|Número|Numero|Teléfono|Telefono):\*[ \t]*([^\n]*)'))[1];
  IF v_nombre = '' OR v_cuenta_raw IS NULL THEN RETURN 'sin_datos'; END IF;

  -- The account, normalized like the Cerebro does: e-mail in lower case, US phone in 10 digits.
  IF position('@' in v_cuenta_raw) > 0 THEN
    v_cuenta := lower(regexp_replace(v_cuenta_raw, '[\s*]', '', 'g'));
  ELSE
    v_cuenta := regexp_replace(v_cuenta_raw, '\D', '', 'g');
    IF length(v_cuenta) = 11 AND left(v_cuenta, 1) = '1' THEN v_cuenta := substr(v_cuenta, 2); END IF;
    IF length(v_cuenta) <> 10 THEN RETURN 'cuenta_invalida'; END IF;
  END IF;

  -- Every word of the name must have been written by the customer (last 24 h), ignoring case and accents.
  SELECT ' ' || regexp_replace(lower(translate(coalesce(string_agg(m.content_text, ' '), ''),
                'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '[^a-z0-9&]+', ' ', 'g') || ' '
    INTO v_cliente
    FROM messages m
   WHERE m.conversation_id = p_conversation_id AND m.sender_type = 'customer'
     AND m.created_at > now() - interval '24 hours';
  SELECT bool_or(position(' ' || w || ' ' in v_cliente) = 0) INTO v_falta
    FROM unnest(regexp_split_to_array(btrim(regexp_replace(lower(translate(v_nombre, 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
                '[^a-z0-9&]+', ' ', 'g')), ' ')) w
   WHERE w <> '';
  IF coalesce(v_falta, true) THEN RETURN 'no_escrito_por_cliente'; END IF;

  -- The ONE open operation whose only current beneficiary is this Zelle account.
  SELECT count(*) INTO v_n
    FROM remittance_operations o
    JOIN remittance_beneficiaries b ON b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
   WHERE o.conversation_id = p_conversation_id AND o.status NOT IN ('completed', 'cancelled')
     AND (SELECT count(*) FROM remittance_beneficiaries x WHERE x.operation_id = o.id AND x.status = 'vigente') = 1
     AND (lower(b.zelle_account) = v_cuenta OR right(regexp_replace(coalesce(b.zelle_account, ''), '\D', '', 'g'), 10) = v_cuenta);
  IF v_n = 0 THEN
    -- (135) No current beneficiary has this account. If the bot confirmed an account that nobody
    -- stored (the extractor missed its format), register it — only when the customer wrote the
    -- account too, the matcher picks ONE remesa and that remesa has no beneficiary at all.
    IF position('@' in v_cuenta) > 0 THEN
      IF position(' ' || regexp_replace(v_cuenta, '[^a-z0-9&]+', ' ', 'g') || ' ' in v_cliente) = 0 THEN
        RETURN 'cuenta_no_escrita_por_cliente';
      END IF;
    ELSE
      SELECT string_agg(regexp_replace(m.content_text, '\D', '', 'g'), '|') INTO v_digitos
        FROM messages m
       WHERE m.conversation_id = p_conversation_id AND m.sender_type = 'customer'
         AND m.created_at > now() - interval '24 hours';
      IF position(v_cuenta in coalesce(v_digitos, '')) = 0 THEN RETURN 'cuenta_no_escrita_por_cliente'; END IF;
    END IF;
    SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conversation_id,
      ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'], v_cuenta);
    IF v_res.resultado IS DISTINCT FROM 'unica' THEN RETURN coalesce(v_res.resultado, 'ninguna'); END IF;
    SELECT o.deal_id, coalesce(o.admin_locked_fields ? 'beneficiaries', false)
      INTO v_deal_id, v_locked
      FROM remittance_operations o WHERE o.id = v_res.operation_id AND o.service_type = 'remesa';
    IF NOT FOUND OR v_deal_id IS NULL THEN RETURN 'sin_deal'; END IF;
    IF v_locked THEN RETURN 'bloqueado'; END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_res.operation_id AND b.status = 'vigente') THEN
      RETURN 'otro_beneficiario';
    END IF;
    UPDATE deals
       SET notes = coalesce(notes, '') || E'\n---\nBENEFICIARIO ZELLE' ||
                   E'\nNombre: ' || v_nombre || E'\nCuenta Zelle: ' || v_cuenta,
           updated_at = now()
     WHERE id = v_deal_id;
    INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_nombre, zelle_cuenta, zelle_nombre_cuenta, actualizado)
    VALUES (p_conversation_id, v_nombre, v_cuenta, v_cuenta, now())
    ON CONFLICT (conversation_id) DO UPDATE
      SET zelle_nombre = EXCLUDED.zelle_nombre, zelle_cuenta = EXCLUDED.zelle_cuenta,
          zelle_nombre_cuenta = EXCLUDED.zelle_nombre_cuenta, actualizado = now();
    RETURN 'registrado';
  END IF;
  IF v_n > 1 THEN RETURN 'ambigua'; END IF;
  SELECT o.id, o.deal_id, coalesce(o.admin_locked_fields ? 'beneficiaries', false), b.name, b.zelle_account
    INTO v_op_id, v_deal_id, v_locked, v_actual, v_cta_guard
    FROM remittance_operations o
    JOIN remittance_beneficiaries b ON b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
   WHERE o.conversation_id = p_conversation_id AND o.status NOT IN ('completed', 'cancelled')
     AND (SELECT count(*) FROM remittance_beneficiaries x WHERE x.operation_id = o.id AND x.status = 'vigente') = 1
     AND (lower(b.zelle_account) = v_cuenta OR right(regexp_replace(coalesce(b.zelle_account, ''), '\D', '', 'g'), 10) = v_cuenta);
  IF v_locked THEN RETURN 'bloqueado'; END IF;
  IF lower(btrim(coalesce(v_actual, ''))) = lower(v_nombre) THEN RETURN 'igual'; END IF;
  IF v_deal_id IS NULL THEN RETURN 'sin_deal'; END IF;

  -- Same block as 'Registrar zelle auto': the deal notes sync applies it.
  UPDATE deals
     SET notes = coalesce(notes, '') || E'\n---\nBENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' ||
                 E'\nNombre: ' || v_nombre || E'\nCuenta Zelle: ' || v_cta_guard,
         updated_at = now()
   WHERE id = v_deal_id;
  UPDATE cerebro_beneficiario_parcial
     SET zelle_nombre = v_nombre, zelle_nombre_cuenta = v_cuenta
   WHERE conversation_id = p_conversation_id
     AND (lower(zelle_cuenta) = v_cuenta OR right(regexp_replace(coalesce(zelle_cuenta, ''), '\D', '', 'g'), 10) = v_cuenta);
  RETURN 'aplicado';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] nombre confirmado no aplicado: %', SQLERRM;
  RETURN 'error';
END $$;

COMMENT ON FUNCTION cerebro_aplicar_nombre_confirmado(uuid, text) IS
  '132/135. Corrects the Zelle holder name with the one the bot confirmed, only for the registered '
  'account, never in repartos or when locked, and only with words the customer wrote; registers a confirmed account nobody stored.';

NOTIFY pgrst, 'reload schema';
