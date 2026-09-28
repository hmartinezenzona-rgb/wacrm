-- =====================================================================
-- 132 — The Zelle holder name the bot CONFIRMS reaches the panel
--
-- The bot (LLM) reads the Zelle holder better than the deterministic path that
-- writes the deal notes. Of 122 confirmations since 1-Aug ("*Nombre:* X /
-- *Celular:* Y"), 113 matched what was stored. In 7 of the 9 mismatches the bot
-- was right: Lisandra Castillo Sanchez (stored "Tata💙🇺🇸", another person),
-- Sampedro, PTK family, Liliana Gonzales Velazquez (stored "Liliana"), Yorlandis
-- Guillen, Yadamy, and Tiger Travel Agency Corp (stored cut, "…Corp (").
-- Approved by the user on 2026-09-28: the panel takes the name the bot confirmed.
--
-- cerebro_aplicar_nombre_confirmado runs on every agent message that carries
-- "*Nombre:*" (trigger below). It only CORRECTS THE NAME, when:
--   - the message has exactly one "*Nombre:*" block (repartos are left alone);
--   - its account equals the only current beneficiary (Zelle) of exactly one
--     open operation of the conversation (it never creates or moves an account);
--   - the beneficiaries are not locked by an operator;
--   - every word of the name was written by the customer in the last 24 h. A
--     bot typo never overwrites what the customer wrote (real case b2952375:
--     customer "Mairenys", bot "Mairensy").
-- Emojis, flags and the word "Zelle" are dropped from the name.
-- It writes the same notes block as the Cerebro's 'Registrar zelle auto' (the
-- deal notes sync applies it) and updates cerebro_beneficiario_parcial so a
-- later burst does not bring the old name back. It never raises: a failure
-- here can never stop a message from being stored.
--
-- ROLLBACK: ROLLBACK-132-zelle-confirmed-name.sql
-- Guarded by supabase/staging/assertions/zelle-confirmed-name.sql
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

  -- The ONE open operation whose only current beneficiary is this Zelle account.
  SELECT count(*) INTO v_n
    FROM remittance_operations o
    JOIN remittance_beneficiaries b ON b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
   WHERE o.conversation_id = p_conversation_id AND o.status NOT IN ('completed', 'cancelled')
     AND (SELECT count(*) FROM remittance_beneficiaries x WHERE x.operation_id = o.id AND x.status = 'vigente') = 1
     AND (lower(b.zelle_account) = v_cuenta OR right(regexp_replace(coalesce(b.zelle_account, ''), '\D', '', 'g'), 10) = v_cuenta);
  IF v_n = 0 THEN RETURN 'otra_cuenta'; END IF;
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
  '132. Corrects the Zelle holder name with the one the bot confirmed, only for the registered '
  'account, never in repartos or when locked, and only with words the customer wrote.';

REVOKE EXECUTE ON FUNCTION cerebro_aplicar_nombre_confirmado(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_aplicar_nombre_confirmado(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION trg_nombre_confirmado_zelle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM cerebro_aplicar_nombre_confirmado(NEW.conversation_id, NEW.content_text);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[cerebro] trigger nombre confirmado: %', SQLERRM;
  END;
  RETURN NULL;
END $$;

REVOKE EXECUTE ON FUNCTION trg_nombre_confirmado_zelle() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_zz_nombre_confirmado_zelle ON messages;
CREATE TRIGGER trg_zz_nombre_confirmado_zelle
  AFTER INSERT ON messages
  FOR EACH ROW
  WHEN (NEW.sender_type = 'agent' AND NEW.content_text LIKE '%*Nombre:*%')
  EXECUTE FUNCTION trg_nombre_confirmado_zelle();

NOTIFY pgrst, 'reload schema';
