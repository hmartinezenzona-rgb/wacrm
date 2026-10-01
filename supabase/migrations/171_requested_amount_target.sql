-- =====================================================================
-- 171 — the amount the customer asked for is the remesa target
--
-- 170 made the service minimum the target, so 3,000 + 10,000 for a 50 USD
-- Zelle stays one remesa. It cannot see a target ABOVE the minimum: a
-- customer who asks for 100 USD Zelle (26,000 GYD) and deposits 13,000 has a
-- remesa that still owes 13,000, but 13,000 already meets the Zelle minimum,
-- so it was verified and released (user, 2026-10-01: "si el cliente dice que
-- quiere 100 zelle y hace un deposito de 13 mil se entiende que aun faltan
-- 13 mil mas").
--
-- Source of truth for "what the customer asked for": the bot's OWN quote,
-- written in a fixed shape the Cerebro always uses, e.g.
--   "Para enviar *100 USD* necesita depositar *26,000 GYD*."
--   "Por *100 USD* por Zelle, Clasica o Tropical necesita depositar *26,000 GYD*"
--   "Por *13,000 GYD* le llegan *50 USD* por Zelle."
--   "Por *30,000 GYD* llegan *90,000 CUP* a Cuba."
-- The customer's own words are free text (and often audio); the quote is the
-- number both sides agreed on. Messages that carry a GYD figure but are NOT
-- a request are ignored: minimums, the exchange rate, per-page fees, and the
-- share of ONE card in a reparto ("... a esa tarjeta", "a cada una").
-- The existing calcular_usd -> cerebro_fijar_objetivo path depends on the LLM
-- calling a tool and is left as it is; this does not.
--
-- What changes:
--   1. cerebro_cotizacion: the latest quote per conversation, written by an
--      AFTER INSERT trigger on the bot's messages. It never blocks a message.
--   2. A quote counts for cotizacion_ventana_horas (6) and only for the remesa
--      after the last closed one of the chat.
--   3. cerebro_objetivo_minimo (170): target = the larger of the service
--      minimum and the quote. It now also brings an open objetivo DOWN to the
--      latest target, so a customer who settles for less is not held.
--   4. A new quote re-evaluates the chat's waiting remesa: if what is already
--      verified covers the new target it is released (ready_to_transfer, with
--      the audit row that makes the notify workflow tell the customer).
--
-- Guarded by supabase/staging/assertions/requested-amount-target.sql (and
-- split-deposit-minimums.sql for 170). ROLLBACK: ROLLBACK-171-requested-amount-target.sql
-- =====================================================================

INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('cotizacion_ventana_horas', '6', 'Horas durante las que la ultima cotizacion del bot es el objetivo de la remesa (171).')
ON CONFLICT (clave) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.cerebro_cotizacion (
  conversation_id uuid PRIMARY KEY REFERENCES public.conversations(id) ON DELETE CASCADE,
  gyd             numeric NOT NULL CHECK (gyd > 0),
  texto           text,
  cotizado_en     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cerebro_cotizacion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cerebro_cotizacion FROM PUBLIC, anon, authenticated;

-- The GYD amount a bot message QUOTES for the remesa, or NULL when the message
-- is not a quote or is ambiguous (two different GYD figures).
CREATE OR REPLACE FUNCTION public.cerebro_monto_cotizado(p_texto text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  WITH t AS (SELECT lower(coalesce(p_texto, '')) AS s),
  vals AS (
    SELECT DISTINCT replace(m[1], ',', '')::numeric AS gyd
      FROM t, regexp_matches(t.s, 'depositar \*([0-9][0-9,]*) gyd\*', 'g') AS m
    UNION
    SELECT DISTINCT replace(m[1], ',', '')::numeric
      FROM t, regexp_matches(t.s, 'por \*([0-9][0-9,]*) gyd\* (?:le )?llegan \*', 'g') AS m
  )
  SELECT CASE WHEN count(*) = 1 THEN min(gyd) END
    FROM vals, t
   WHERE t.s !~ '(m[ií]nimo|la tasa es \*|tasa se mantiene|a esa tarjeta|a cada|p[aá]gina|per page|hoja)';
$$;

-- The quote that is the target of the chat's CURRENT remesa, if any.
CREATE OR REPLACE FUNCTION public.cerebro_cotizacion_vigente(p_conv uuid)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.gyd
    FROM cerebro_cotizacion c
   WHERE c.conversation_id = p_conv
     AND c.cotizado_en > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('cotizacion_ventana_horas'), '')::int, 6))
     AND c.cotizado_en > COALESCE((SELECT max(COALESCE(o.completed_at, o.cancelled_at))
                                     FROM remittance_operations o
                                    WHERE o.conversation_id = p_conv
                                      AND o.status IN ('completed', 'cancelled')), '-infinity'::timestamptz);
$$;

-- (171) 170's function, with the quote in the target and able to lower an open objetivo.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op   uuid;
  v_tot  numeric;
  v_meta numeric;
  v_obj  numeric;
  v_hay  boolean;
BEGIN
  SELECT o.id, o.quoted_source_amount INTO v_op, v_tot FROM remittance_operations o WHERE o.deal_id = p_deal;
  IF v_op IS NULL THEN RETURN NULL; END IF;
  -- The latest quote is the target; without one, an objetivo already open (e.g. from
  -- calcular_usd) is kept, never lowered to the bare minimum.
  v_meta := greatest(cerebro_minimo_gyd(v_op),
                     COALESCE(cerebro_cotizacion_vigente(p_conv),
                              (SELECT x.monto FROM cerebro_objetivo_envio x
                                WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL),
                              0));
  -- Another deal of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.deal_id IS NOT NULL AND x.deal_id <> p_deal) THEN
    RETURN NULL;
  END IF;
  v_hay := EXISTS (SELECT 1 FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  -- Covered and nothing open to correct: nothing to do.
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), p_deal, NULL, 'objetivo del envio (171)')
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto      = EXCLUDED.monto,
    moneda     = 'GYD',
    deal_id    = p_deal,
    pedido     = EXCLUDED.pedido,
    fijado_en  = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $$;

-- A new quote re-targets the chat's waiting remesa and releases it when what is
-- already verified covers the new target.
CREATE OR REPLACE FUNCTION public.cerebro_aplicar_cotizacion(p_conv uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op   record;
  v_sal  record;
  v_n    integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id, o.deal_id
      FROM remittance_operations o JOIN deals d ON d.id = o.deal_id
     WHERE o.conversation_id = p_conv
       AND o.service_type = 'remesa'
       AND o.status = 'deposit_verification'
       AND d.status = 'open'
       AND o.created_at > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6))
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    PERFORM cerebro_objetivo_minimo(p_conv, v_op.deal_id);
    PERFORM cerebro_cruzar_pendientes(v_op.deal_id);
    SELECT * INTO v_sal FROM cerebro_saldo_envio(v_op.deal_id);
    IF (SELECT status FROM remittance_operations WHERE id = v_op.id) = 'deposit_verification'
       AND v_sal.objetivo IS NOT NULL AND v_sal.depositado > 0 AND v_sal.saldo <= 0
       AND NOT EXISTS (SELECT 1 FROM depositos_mmg m JOIN deals d ON d.id = v_op.deal_id
                        WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL
                          AND d.notes LIKE '%Ref: ' || m.trans_id || '%') THEN
      UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op.id;
      PERFORM cerebro_objetivo_cerrar(v_op.deal_id);
    END IF;
    IF (SELECT status FROM remittance_operations WHERE id = v_op.id) = 'ready_to_transfer' THEN
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
      VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'status', 'automation_late_deposit_verification', NULL,
              'The customer''s new quote is covered by the verified deposits (171).',
              jsonb_build_object('status', 'deposit_verification'),
              jsonb_build_object('status', 'ready_to_transfer', 'objetivo', v_sal.objetivo, 'depositado', v_sal.depositado));
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_cotizacion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gyd numeric;
BEGIN
  BEGIN
    v_gyd := cerebro_monto_cotizado(NEW.content_text);
    IF v_gyd IS NOT NULL THEN
      INSERT INTO cerebro_cotizacion (conversation_id, gyd, texto, cotizado_en)
      VALUES (NEW.conversation_id, v_gyd, left(NEW.content_text, 500), now())
      ON CONFLICT (conversation_id) DO UPDATE
        SET gyd = EXCLUDED.gyd, texto = EXCLUDED.texto, cotizado_en = EXCLUDED.cotizado_en;
      PERFORM cerebro_aplicar_cotizacion(NEW.conversation_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- A quote that cannot be recorded must never lose the bot's message.
    RAISE WARNING '[wacrm] cerebro_registrar_cotizacion failed for conversation %: %', NEW.conversation_id, SQLERRM;
  END;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_registrar_cotizacion ON public.messages;
CREATE TRIGGER trg_registrar_cotizacion
  AFTER INSERT ON public.messages
  FOR EACH ROW
  WHEN (NEW.sender_type = 'agent' AND NEW.ai_generated IS TRUE AND NEW.content_text LIKE '%GYD*%')
  EXECUTE FUNCTION public.cerebro_registrar_cotizacion();

REVOKE ALL ON FUNCTION public.cerebro_monto_cotizado(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_cotizacion_vigente(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_aplicar_cotizacion(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_registrar_cotizacion() FROM PUBLIC, anon, authenticated;
