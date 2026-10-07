-- =====================================================================
-- 223 -- "Saldo movil" as an operation service (staging first)
--
-- odd/tasks/saldo-movil-service.md (T1). A mobile balance top-up to a Cuban phone (a "recarga de saldo") is an operation
-- service of its own, not an Etecsa promotion recharge. Owner 2026-10-06: sold in fixed packages, 1,000 GYD = 360 of
-- saldo. Until now the only way to file one (Yilian 6709a0cd, 5,000 GYD) was service_type 'recarga', which is promo
-- bound and priced by precio_recarga, so its ledger line stayed pending. Modelled on 213 (visa: the touchpoints of a
-- new service) and 198/199 (recarga: phone-only recipient, USDT cost, ledger).
--
--   A. DATA
--      - remittance_operations_service_chk gains 'saldo'. The recipient is the existing phone-only 'recarga' row type
--        (rb_type_chk unchanged), exactly ONE per saldo (one Cuban number receives every package).
--      - cerebro_config: precio_saldo_gyd = 1000 (price of a package) and saldo_unidad_cup = 360 (saldo per package; read
--        by the app card and the later bot). Price and size are data, not code. Not promo-bound: sold all year.
--      - calculator_rate_versions.saldo_costo_usdt (USDT cost of one package, NULL until the owner sets it);
--        crm_set_calculator_rates accepts it, like recarga_costo_usdt.
--      - cerebro_saldo_precio() and cerebro_saldo_paquetes(deposit): the package price, and deposit / price when the
--        deposit is a whole multiple (NULL otherwise: no silent rounding).
--   B. SERVICE ENUMERATIONS (rail 'saldo', minimum = one package, objetivo 'minimo saldo movil')
--      - cerebro_riel_op, cerebro_minimo_gyd, cerebro_objetivo_minimo, crm_operaciones_de_conversacion (open and the
--        last completed ones), crm_cerrar_operacion_manual (picker accepts 'saldo'), crm_cambiar_servicio (a remesa or
--        recarga becomes a saldo: every recipient is retired, the service is locked against the bot, one audit row).
--      - crm_beneficiarios_completos: complete with exactly one valid Cuban mobile. crm_agregar_beneficiario: a saldo
--        takes one phone-only recipient (a second, a card or a landline is refused).
--   C. REMESA WRITERS LEAVE A SALDO ALONE (as 213 does for a visa): cerebro_resolver_operacion_beneficiario never
--      picks it as the remesa target, cerebro_escribir_bloque_beneficiario never writes ON it, and
--      cerebro_avisar_envios_sin_beneficiario (the "no recipient" customer notice) skips it. No message is sent by any
--      of this.
--   D. LEDGER
--      - calculator_service_for_operation / calculator_resolve_operation_service map saldo -> SALDO_MOVIL;
--        calculator_missing_rates('SALDO_MOVIL') asks for saldoCostoUsdt and usdtBuyGyd.
--      - calculator_feed_operation, SALDO_MOVIL: units = deposit / price when exact, facturado = units x price,
--        invertido = units x saldo_costo_usdt x usdt_buy_gyd, retorno = the difference; amount currency 'REC' (units),
--        snapshot cup_rate = usdt_buy_gyd, cost_gyd = saldo_costo_usdt, sale_gyd = price (like a RECARGA line). A missing
--        cost leaves the line pending naming saldoCostoUsdt; a deposit that is not a whole multiple leaves it pending
--        naming saldoPaquetes.
--      - GAP FIXED, crm_resolve_pending_entry: it priced EVERY pending line as a USD service (units = floor(deposit /
--        sell rate)), so a pending RECARGA line would have been resolved with a Zelle-style rate and no recharge
--        cost. RECARGA and SALDO_MOVIL now have their own branch (decision: own branch rather than excluding them like
--        COMBO/VISA, because a pending saldo line is the NORMAL case until the owner sets the cost and nothing re-feeds
--        a pending line; excluding it would leave it stuck): the payload may carry recarga_costo_usdt / saldo_costo_usdt
--        and usdt_buy_gyd, what the line already recorded wins, and the price is the one the feed uses. A saldo
--        deposit that is not a whole number of packages (and a recharge deposit matching no price) is refused: a
--        person fixes the deposit and re-feeds. canResolveWithRates stays true for both.
--
-- Not touched (second step, bot): cerebro_registrar_deposito, cerebro_servicio_get, the n8n flow. A deposit that
-- arrives for a conversation with an open saldo is still a remesa deposit.
-- Assertion: supabase/staging/assertions/saldo-model.sql. Rollback: ROLLBACK-223-saldo-movil-service.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Data
-- ---------------------------------------------------------------------
ALTER TABLE remittance_operations DROP CONSTRAINT remittance_operations_service_chk;
ALTER TABLE remittance_operations ADD CONSTRAINT remittance_operations_service_chk
  CHECK (service_type = ANY (ARRAY['remesa'::text, 'combo'::text, 'recarga'::text, 'visa'::text, 'traduccion'::text, 'mexico'::text, 'saldo'::text]));

INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('precio_saldo_gyd', '1000', 'Precio en GYD de un paquete de saldo movil (223). El minimo de un saldo es un paquete; el deposito debe ser multiplo exacto.'),
  ('saldo_unidad_cup', '360', 'Saldo (CUP) que recibe el numero cubano por cada paquete de saldo movil (223).')
ON CONFLICT (clave) DO NOTHING;

ALTER TABLE public.calculator_rate_versions
  ADD COLUMN IF NOT EXISTS saldo_costo_usdt numeric CHECK (saldo_costo_usdt IS NULL OR (saldo_costo_usdt > 0 AND saldo_costo_usdt < 1e6));
COMMENT ON COLUMN public.calculator_rate_versions.saldo_costo_usdt IS '223. Cost of one package of mobile balance in USDT (priced in GYD with usdt_buy_gyd).';

CREATE OR REPLACE FUNCTION public.cerebro_saldo_precio()
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (223) The price of one package of mobile balance (cerebro_config precio_saldo_gyd; 1,000 GYD when unset or not positive).
  SELECT coalesce((SELECT x.v FROM (SELECT nullif(cerebro_config_get('precio_saldo_gyd'), '')::numeric AS v) x WHERE x.v > 0), 1000);
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_saldo_paquetes(p_deposito numeric)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (223) Packages in a deposit: deposit / price when it is a whole multiple, NULL otherwise (no silent rounding).
  SELECT CASE WHEN p_deposito > 0 AND mod(p_deposito, cerebro_saldo_precio()) = 0
              THEN (p_deposito / cerebro_saldo_precio())::integer END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_saldo_precio(), public.cerebro_saldo_paquetes(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_saldo_precio(), public.cerebro_saldo_paquetes(numeric) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- B, C, D. The redefined functions (current staging definitions + the saldo edits)
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- cerebro_riel_op
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_riel_op(p_op uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN o.service_type = 'recarga' THEN 'recarga'
              -- (209) a combo has its own rail (its recipients are 'combo' rows, but it can have none yet)
              WHEN o.service_type = 'combo' THEN 'combo'
              -- (213) a visa has no recipients at all: its own rail
              WHEN o.service_type = 'visa' THEN 'visa'
              -- (223) a mobile balance top-up has its own rail (its recipient is a phone-only 'recarga' row)
              WHEN o.service_type = 'saldo' THEN 'saldo' ELSE COALESCE(
    NULLIF(o.delivery_method, ''),
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = o.id AND b.status = 'vigente' ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = o.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = o.conversation_id AND bp.actualizado > now() - interval '24 hours')) END
    FROM remittance_operations o
   WHERE o.id = p_op;
$function$;

-- ---------------------------------------------------------------------
-- cerebro_minimo_gyd
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_riel text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = p_op) THEN RETURN NULL; END IF;
  v_riel := cerebro_riel_op(p_op);
  RETURN CASE
    WHEN v_riel = 'recarga'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200)
    -- (209) A combo: 25,000 GYD per recipient (at least one).
    WHEN v_riel = 'combo'
      THEN 25000 * greatest(1, (SELECT count(*) FROM remittance_beneficiaries b
                                 WHERE b.operation_id = p_op AND b.status = 'vigente'))
    -- (213) A visa extension: 5,000 GYD per person (the deposit says how many).
    WHEN v_riel = 'visa' THEN 5000
    -- (223) A mobile balance: one package (precio_saldo_gyd, 1,000 GYD).
    WHEN v_riel = 'saldo' THEN cerebro_saldo_precio()
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN cerebro_minimo_efectivo_gyd()  -- (188) 100 USD x the calculator cash rate
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $function$;

-- ---------------------------------------------------------------------
-- cerebro_objetivo_minimo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op     uuid := cerebro_resolve_op_id(p_deal);
  v_deal   uuid;
  v_tot    numeric;
  v_min    numeric;
  v_cot    numeric;
  v_prev   numeric;
  v_meta   numeric;
  v_pedido text;
  v_obj    numeric;
  v_hay    boolean;
BEGIN
  SELECT o.deal_id, o.quoted_source_amount INTO v_deal, v_tot FROM remittance_operations o WHERE o.id = v_op;
  IF v_op IS NULL OR NOT FOUND THEN RETURN NULL; END IF;
  v_min  := cerebro_minimo_gyd(v_op);
  v_cot  := cerebro_cotizacion_vigente(p_conv);
  v_prev := (SELECT x.monto FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  v_meta := greatest(v_min, COALESCE(v_cot, v_prev, 0));
  v_pedido := CASE
    WHEN v_cot IS NOT NULL AND v_cot >= v_min THEN 'cotizacion'
    WHEN v_cot IS NULL AND v_prev IS NOT NULL AND v_prev > v_min THEN NULL
    ELSE 'minimo ' || CASE cerebro_riel_op(v_op)
                        WHEN 'zelle' THEN 'Zelle'
                        WHEN 'clasica' THEN 'Clásica'
                        WHEN 'tropical' THEN 'Tropical'
                        WHEN 'efectivo_usd' THEN 'efectivo en USD'
                        WHEN 'recarga' THEN 'recarga'
                        WHEN 'combo' THEN 'combo'  -- (209)
                        WHEN 'visa' THEN 'extension de visa'  -- (213)
                        WHEN 'saldo' THEN 'saldo movil'  -- (223)
                        ELSE 'tarjeta CUP' END
  END;
  -- Another operation of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.operation_id IS NOT NULL AND x.operation_id <> v_op) THEN
    RETURN NULL;
  END IF;
  v_hay := v_prev IS NOT NULL;
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido, operation_id)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), v_deal, NULL,
          COALESCE(v_pedido, 'objetivo del envio'), v_op)
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto        = EXCLUDED.monto,
    moneda       = 'GYD',
    deal_id      = v_deal,
    operation_id = v_op,
    pedido       = COALESCE(v_pedido, cerebro_objetivo_envio.pedido),
    fijado_en    = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en   = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $function$;

-- ---------------------------------------------------------------------
-- crm_operaciones_de_conversacion
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_operaciones_de_conversacion(p_conversation_id uuid)
 RETURNS TABLE(resolver_resultado text, resolver_operation_id uuid, resolver_candidatas integer, operation_id uuid, operation_status text, operation_service_type text, operation_source_currency text, operation_destination_currency text, operation_delivery_method text, operation_deposit_method text, operation_quoted_source_amount numeric, operation_quoted_destination_amount numeric, operation_admin_locked_fields jsonb, operation_created_at timestamp with time zone, operation_completed_at timestamp with time zone, beneficiary_id uuid, beneficiary_type text, beneficiary_name text, beneficiary_card_number text, beneficiary_phone text, beneficiary_zelle_account text, beneficiary_delivery_method text, beneficiary_amount numeric, beneficiary_currency text, beneficiary_position integer, operation_quoted_destination_rate numeric, operation_quoted_destination_origin text, beneficiary_amount_origin text, operation_is_history boolean, operation_beneficiaries_complete boolean, operation_delivery_mode text, operation_delivered_at timestamp with time zone, beneficiary_address text, beneficiary_id_photo_wamid text, beneficiary_id_photo_url text, beneficiary_reference text, beneficiary_contact_phone text, operation_combo_costo_gyd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id            uuid;
  v_resolver_resultado    text;
  v_resolver_operation_id uuid;
  v_resolver_candidatas   integer;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  SELECT c.account_id INTO v_account_id
    FROM conversations c
   WHERE c.id = p_conversation_id;

  -- Same 42501 whether the conversation doesn't exist or belongs to an
  -- account the caller isn't a member of — see 097's file header for why.
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  -- Inlined, NOT called by name — see 097's file header's "WHY THE
  -- RESOLVER LOGIC IS INLINED" section. Unchanged by this migration: the
  -- resolver only ever looks at live (non-terminal) operations, regardless
  -- of the history rows the RETURN QUERY below now also surfaces.
  SELECT count(*) INTO v_resolver_candidatas
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');

  IF v_resolver_candidatas = 0 THEN
    v_resolver_resultado := 'ninguna';
    v_resolver_operation_id := NULL;
  ELSIF v_resolver_candidatas = 1 THEN
    v_resolver_resultado := 'unica';
    SELECT o.id INTO v_resolver_operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
  ELSE
    v_resolver_resultado := 'ambigua';
    v_resolver_operation_id := NULL;
  END IF;

  RETURN QUERY
  WITH ops AS (
    -- Current open (non-terminal) remesa operations — same set the RPC
    -- has always returned.
    SELECT o.*, false AS is_history
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled')
       AND o.service_type IN ('remesa', 'recarga', 'combo', 'visa', 'saldo')  -- (200) recharges too, (208) combos, (213) visas, (223) mobile balances
    UNION ALL
    -- The 10 most recently completed remesa operations of the same
    -- conversation — read-only history. A completed operation can never
    -- also match the branch above (status is exclusive), so UNION ALL
    -- cannot duplicate a row.
    SELECT h.*, true AS is_history
      FROM (
        SELECT o2.*
          FROM remittance_operations o2
         WHERE o2.conversation_id = p_conversation_id
           AND o2.status = 'completed'
           AND o2.service_type IN ('remesa', 'recarga', 'combo', 'visa', 'saldo')  -- (200), (208), (223)
         ORDER BY o2.completed_at DESC
         LIMIT 10
      ) h
  )
  SELECT
    r.resultado,
    r.operation_id,
    r.candidatas,
    o.id,
    o.status,
    o.service_type,
    o.source_currency,
    o.destination_currency,
    o.delivery_method,
    o.deposit_method,
    o.quoted_source_amount,
    o.quoted_destination_amount,
    o.admin_locked_fields,
    o.created_at,
    o.completed_at,
    b.id,
    b.beneficiary_type,
    b.name,
    b.card_number,
    b.phone,
    b.zelle_account,
    b.delivery_method,
    b.amount,
    b.currency,
    b.position,
    o.quoted_destination_rate,
    o.quoted_destination_origin,
    b.amount_origin,
    o.is_history,
    CASE WHEN o.id IS NULL THEN NULL ELSE crm_beneficiarios_completos(o.id) END,
    o.delivery_mode,
    CASE WHEN o.is_history THEN o.completed_at ELSE NULL END,
    -- (189) a cash recipient (150): address and the ID-card photo, with the URL of the message it came in.
    b.address,
    b.id_photo_wamid,
    (SELECT m.media_url FROM messages m
      WHERE b.id_photo_wamid IS NOT NULL AND m.message_id = b.id_photo_wamid
        AND m.conversation_id = o.conversation_id
      ORDER BY m.created_at DESC LIMIT 1),
    -- (208) A combo recipient: how to get there and the second contact phone; the combo's cost (set by the admin).
    b.reference,
    b.contact_phone,
    o.combo_costo_gyd
  -- A single synthetic one-row source (no FROM) rather than a set-returning
  -- call, so the resolver values still surface even when zero operations
  -- match below (the 'ninguna' case) — LEFT JOIN against zero rows on the
  -- left would otherwise return zero rows overall, not one resolver-only row.
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN ops o ON true
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.is_history ASC NULLS LAST, o.created_at DESC NULLS LAST, o.completed_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $function$;

-- ---------------------------------------------------------------------
-- crm_cerrar_operacion_manual
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text DEFAULT NULL::text, p_notify boolean DEFAULT false, p_delivery_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_completed_at  timestamptz;
  v_motivo        text := coalesce(nullif(btrim(p_motivo), ''), 'Closed manually from the panel');
BEGIN
  SELECT account_id, status INTO v_account_id, v_status_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  -- (191) No typed reason any more: the fixed note above is audited unless one is given.
  IF length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'the reason must be at most 500 characters' USING ERRCODE = '22023';
  END IF;
  -- (196) The service chosen in the panel when the remesa has no beneficiary, so the calculator can price it.
  IF p_delivery_method IS NOT NULL THEN
    IF p_delivery_method NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      RAISE EXCEPTION 'unknown service: %', p_delivery_method USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'this remesa already has a beneficiary: its service comes from it' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid(),
         -- (196) In the same UPDATE, so the calculator feed (AFTER UPDATE OF status) sees the service.
         -- (200) 'recarga' is a kind of operation, not a delivery method: it sets service_type. (208) So is 'combo'. (213) And 'visa'. (223) And 'saldo'.
         delivery_method = CASE WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN delivery_method ELSE coalesce(p_delivery_method, delivery_method) END,
         service_type = CASE WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN p_delivery_method ELSE service_type END,
         -- (191) Silent by default (p_notify false); the bell on the panel can turn the notice on.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually', 'notify', p_notify)
            || CASE WHEN p_delivery_method IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('delivery_method', p_delivery_method) END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

-- ---------------------------------------------------------------------
-- crm_cambiar_servicio
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_cambiar_servicio(p_operation_id uuid, p_servicio text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op         remittance_operations%ROWTYPE;
  v_servicio   text := lower(btrim(coalesce(p_servicio, '')));
  v_actual     text;
  v_card_types constant text[] := ARRAY['cuban_card', 'clasica', 'tropical'];
  v_new_type   text;
  v_new_dm     text;
  v_fit        integer;
  v_mixed      integer;
  v_retired    uuid[];
  v_retyped    uuid[];
  v_before     jsonb;
  v_after      jsonb;
  v_lock       jsonb;
  v_single     remittance_beneficiaries%ROWTYPE;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_op.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to change the service of this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
    RAISE EXCEPTION 'unknown service: %', p_servicio USING ERRCODE = '22023';
  END IF;

  IF v_op.service_type NOT IN ('remesa', 'recarga', 'combo', 'visa', 'saldo') THEN
    RAISE EXCEPTION 'the service of a % operation cannot be changed here', v_op.service_type USING ERRCODE = '22023';
  END IF;

  v_actual := cerebro_riel_op(p_operation_id);
  IF v_actual IS NOT DISTINCT FROM v_servicio THEN
    RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', false);
  END IF;

  v_new_type := CASE WHEN v_servicio IN ('recarga', 'combo', 'visa', 'saldo') THEN v_servicio ELSE 'remesa' END;
  v_new_dm   := CASE WHEN v_new_type = 'remesa' THEN v_servicio END;

  -- Which current recipients fit the new service (a card rail also takes multiple_distribution on CUP).
  SELECT count(*) INTO v_fit
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
     AND CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
              WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
              WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
              WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
              ELSE false END;

  -- Several card shares with their own amounts cannot move between CUP and USD: there is nothing to recompute them from.
  IF v_servicio IN ('cuban_card', 'clasica', 'tropical') AND v_fit > 1 THEN
    SELECT count(*) INTO v_mixed
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND b.beneficiary_type = ANY (v_card_types)
       AND (b.beneficiary_type = 'cuban_card') <> (v_servicio = 'cuban_card');
    IF v_mixed > 0 THEN
      RAISE EXCEPTION 'several recipients with their own amounts cannot change between CUP and USD: correct them one by one' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_before := jsonb_build_object(
    'service', v_actual, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'recipients', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'type', b.beneficiary_type) ORDER BY b.position), '[]'::jsonb)
                     FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente'));

  -- 1. The operation: new service, quote cleared, rail locked against the bot. The 096 guard locks the changed
  --    destination fields for a human writer; they are released right after (2).
  UPDATE remittance_operations
     SET service_type = v_new_type,
         delivery_method = v_new_dm,
         destination_currency = NULL,
         quoted_destination_amount = NULL,
         quoted_destination_rate = NULL,
         quoted_destination_origin = NULL,
         combo_costo_gyd = CASE WHEN v_new_type = 'combo' THEN combo_costo_gyd END,
         admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb)
           || jsonb_build_object('delivery_method', jsonb_build_object('by', wacrm_current_actor(), 'at', now()),
                                 'service_type', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  -- 2. The quote is calculated, not manual: release the destination locks so the calculation can write it.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
   WHERE id = p_operation_id;

  -- 3. Recipients that do not fit are retired.
  WITH r AS (
    UPDATE remittance_beneficiaries b
       SET status = 'reemplazado', replaced_at = now()
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND NOT CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
                    WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
                    WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
                    WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
                    ELSE false END
    RETURNING b.id)
  SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_retired FROM r;

  -- 4. Recipients that fit: a card rail re-types the card; a lone recipient is priced again.
  IF v_servicio IN ('cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd') THEN
    WITH k AS (
      UPDATE remittance_beneficiaries b
         SET beneficiary_type = CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN v_servicio ELSE b.beneficiary_type END,
             amount = CASE WHEN v_fit = 1 THEN NULL ELSE b.amount END,
             currency = CASE WHEN v_fit = 1 THEN NULL ELSE b.currency END,
             amount_origin = CASE WHEN v_fit = 1 THEN NULL ELSE b.amount_origin END
       WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
         AND (v_fit = 1 OR (v_servicio IN ('cuban_card', 'clasica', 'tropical') AND b.beneficiary_type <> v_servicio))
         AND NOT (v_servicio = 'cuban_card' AND b.beneficiary_type = 'multiple_distribution')
      RETURNING b.id)
    SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_retyped FROM k;
  ELSE
    v_retyped := ARRAY[]::uuid[];
  END IF;

  -- 5. The existing calculation prices the operation again (the recipient triggers have already run it; this covers
  --    the case where nothing was re-typed). A lone recipient of an operation whose recipients were locked by an earlier
  --    correction does not get its amount from the calculation, so it takes the recalculated quote here.
  PERFORM crm_calcular_monto_destino(p_operation_id);
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF v_op.quoted_destination_origin = 'calculated' THEN
    SELECT * INTO v_single FROM remittance_beneficiaries
     WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'combo' ORDER BY position LIMIT 1;
    IF v_single.id IS NOT NULL
       AND (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente') = 1
       AND (v_single.amount IS DISTINCT FROM v_op.quoted_destination_amount
            OR v_single.currency IS DISTINCT FROM v_op.destination_currency) THEN
      UPDATE remittance_beneficiaries
         SET amount = v_op.quoted_destination_amount, currency = v_op.destination_currency, amount_origin = 'calculated'
       WHERE id = v_single.id;
    END IF;
  END IF;

  -- 6. The calculation's own writes were locked by the guard (the writer is a human): release them again.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
   WHERE id = p_operation_id
     AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];

  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  v_after := jsonb_build_object(
    'service', v_servicio, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'retired_recipients', to_jsonb(v_retired), 'retyped_recipients', to_jsonb(v_retyped));

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_op.account_id, 'remittance_operations', p_operation_id, 'service', 'human_correction',
          wacrm_current_actor(), v_before, v_after);

  RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', true,
                            'retired_recipients', coalesce(array_length(v_retired, 1), 0),
                            'retyped_recipients', coalesce(array_length(v_retyped, 1), 0));
END $function$;

-- ---------------------------------------------------------------------
-- crm_beneficiarios_completos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_beneficiarios_completos(p_operation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (198) A recharge: every current row is a 'recarga' with a valid Cuban mobile, and there are as many as
  -- recharges (cerebro_recarga_unidades; with no matching price, at least one).
  SELECT coalesce((SELECT CASE WHEN o.service_type = 'recarga' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'recarga'
                                AND coalesce(cerebro_norm_celular_cu(b.phone), '') ~ '^[0-9]{8}$')
                   AND count(*) >= coalesce(cerebro_recarga_unidades(o.quoted_source_amount), 0)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         -- (223) A mobile balance: exactly ONE current recipient, a 'recarga' row with a valid Cuban mobile (one number
         -- receives every package).
         WHEN o.service_type = 'saldo' THEN
           (SELECT count(*) = 1
                   AND bool_and(b.beneficiary_type = 'recarga'
                                AND coalesce(cerebro_norm_celular_cu(b.phone), '') ~ '^[0-9]{8}$')
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         -- (208) A combo: at least one current recipient, and every one has name, phone, address, reference and an
         -- amount of at least 25,000 GYD (the minimum per combo). The address names the province, and a second contact
         -- phone is optional (owner 2026-10-04).
         WHEN o.service_type = 'combo' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'combo'
                                AND btrim(coalesce(b.name, '')) <> '' AND btrim(coalesce(b.phone, '')) <> ''
                                AND btrim(coalesce(b.address, '')) <> '' AND cerebro_combo_provincia(b.address) IS NOT NULL
                                AND btrim(coalesce(b.reference, '')) <> ''
                                AND coalesce(b.amount, 0) >= 25000)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         -- (213) A visa extension needs no recipient: the customer fills the online form himself, so it is complete once open.
         WHEN o.service_type = 'visa' THEN true
         ELSE (
    SELECT
      count(*) > 0
      AND bool_and(
        CASE
          WHEN beneficiary_type = 'zelle' THEN
            btrim(coalesce(name, '')) <> '' AND btrim(coalesce(zelle_account, '')) <> ''
          -- (188) A cash recipient has no card: phone, address and ID-card photo (150).
          WHEN beneficiary_type = 'efectivo_usd' THEN
            btrim(coalesce(phone, '')) <> '' AND btrim(coalesce(address, '')) <> ''
            AND btrim(coalesce(id_photo_wamid, '')) <> ''
          ELSE
            btrim(coalesce(card_number, '')) <> '' AND btrim(coalesce(phone, '')) <> ''
        END
      )
    FROM remittance_beneficiaries
    WHERE operation_id = p_operation_id
      AND status = 'vigente'
         ) END
    FROM remittance_operations o
   WHERE o.id = p_operation_id), false);
$function$;

-- ---------------------------------------------------------------------
-- crm_agregar_beneficiario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_agregar_beneficiario(p_operation_id uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id        uuid;
  v_op_status          text;
  v_service_type       text;
  v_key                text;
  v_new_id             uuid;
  v_next_position      integer;
  v_next_block_index   integer;

  v_beneficiary_type   text;
  v_name               text;
  v_card_number        text;
  v_phone              text;
  v_zelle_account      text;
  v_delivery_method    text;
  v_amount             numeric;
  v_currency           text;
  v_address            text;
  v_reference          text;
  v_contact            text;
BEGIN
  SELECT account_id, status, service_type
    INTO v_account_id, v_op_status, v_service_type
    FROM remittance_operations
   WHERE id = p_operation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to add a beneficiary to this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_service_type IS NULL OR v_service_type NOT IN ('remesa', 'recarga', 'combo', 'saldo') THEN
    RAISE EXCEPTION 'beneficiaries can only be added to remesa, recarga, saldo or combo operations' USING ERRCODE = '22023';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'datos must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- Reject unknown keys up front, same posture as crm_corregir_beneficiario.
  FOR v_key IN SELECT jsonb_object_keys(p_datos) LOOP
    IF v_key NOT IN ('beneficiary_type', 'name', 'card_number', 'phone', 'zelle_account',
                      'delivery_method', 'amount', 'currency', 'address', 'reference', 'contact_phone') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_beneficiary_type := p_datos ->> 'beneficiary_type';
  IF v_beneficiary_type IS NULL
     OR v_beneficiary_type NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'recarga', 'combo') THEN
    RAISE EXCEPTION 'invalid beneficiary_type: %', v_beneficiary_type USING ERRCODE = '22023';
  END IF;

  -- (208) A combo takes combo recipients only, and only a combo does. Address, reference and contact_phone belong to
  -- a combo recipient alone.
  IF (v_service_type = 'combo') <> (v_beneficiary_type = 'combo') THEN
    RAISE EXCEPTION 'a combo takes combo recipients only, and no other operation does' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type <> 'combo' AND (p_datos ? 'address' OR p_datos ? 'reference' OR p_datos ? 'contact_phone') THEN
    RAISE EXCEPTION 'unknown field: address, reference and contact_phone are for combo recipients' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type = 'combo' THEN
    v_name := nullif(btrim(coalesce(p_datos ->> 'name', '')), '');
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'name is required for a combo recipient' USING ERRCODE = '22023';
    END IF;
    v_phone := regexp_replace(coalesce(p_datos ->> 'phone', ''), '[^0-9]', '', 'g');
    IF length(v_phone) = 10 AND left(v_phone, 2) = '53' THEN v_phone := substr(v_phone, 3); END IF;
    IF v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_contact := nullif(regexp_replace(coalesce(p_datos ->> 'contact_phone', ''), '[^0-9]', '', 'g'), '');
    IF v_contact IS NOT NULL AND length(v_contact) = 10 AND left(v_contact, 2) = '53' THEN v_contact := substr(v_contact, 3); END IF;
    IF v_contact IS NOT NULL AND v_contact !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'contact_phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_address := nullif(btrim(coalesce(p_datos ->> 'address', '')), '');
    v_reference := nullif(btrim(coalesce(p_datos ->> 'reference', '')), '');
    IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL OR (p_datos ->> 'amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
    END IF;
    v_amount := (p_datos ->> 'amount')::numeric;
    IF coalesce(p_datos ->> 'currency', 'GYD') <> 'GYD' THEN
      RAISE EXCEPTION 'a combo amount is in GYD' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, reference, contact_phone,
                                          amount, currency, position, status, source, block_index)
    VALUES (p_operation_id, 'combo', v_name, v_phone, v_address, v_reference, v_contact,
            v_amount, 'GYD', v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now())),
           quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                    WHERE b.operation_id = p_operation_id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,phone,address,reference,contact_phone,amount,currency',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- (200) A recharge takes recharge numbers only (one Cuban mobile per recharge), and a remesa none: no card, no
  -- amount. Same lock and audit as below.
  -- (223) A mobile balance takes one phone-only recipient, the same row type as a recharge.
  IF (v_service_type IN ('recarga', 'saldo')) <> (v_beneficiary_type = 'recarga') THEN
    RAISE EXCEPTION 'a recharge or a mobile balance takes recharge numbers only, and a remesa none' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type = 'recarga' THEN
    v_phone := cerebro_norm_celular_cu(p_datos ->> 'phone');
    IF coalesce(v_phone, '') !~ '^[0-9]{8}$' THEN
      RAISE EXCEPTION 'phone must be a Cuban mobile number' USING ERRCODE = '22023';
    END IF;
    IF v_service_type = 'saldo' AND EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'a mobile balance has one number: correct it instead of adding another' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, status, source, block_index)
    VALUES (p_operation_id, 'recarga', v_phone, v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,phone',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- amount and currency are required: unlike a correction, a newly added
  -- beneficiary has no prior row to fall back on for its destination amount.
  IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL
     OR (p_datos ->> 'amount')::numeric <= 0 THEN
    RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
  END IF;
  v_amount := (p_datos ->> 'amount')::numeric;

  IF NOT (p_datos ? 'currency') OR p_datos ->> 'currency' IS NULL
     OR p_datos ->> 'currency' !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency is required and must be a 3-letter uppercase code' USING ERRCODE = '22023';
  END IF;
  v_currency := p_datos ->> 'currency';

  v_delivery_method := p_datos ->> 'delivery_method';
  IF p_datos ? 'delivery_method' AND btrim(coalesce(v_delivery_method, '')) = '' THEN
    RAISE EXCEPTION 'delivery_method must not be empty' USING ERRCODE = '22023';
  END IF;

  IF v_beneficiary_type = 'zelle' THEN
    v_name := p_datos ->> 'name';
    v_zelle_account := p_datos ->> 'zelle_account';
    IF btrim(coalesce(v_name, '')) = '' THEN
      RAISE EXCEPTION 'name is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    IF btrim(coalesce(v_zelle_account, '')) = '' THEN
      RAISE EXCEPTION 'zelle_account is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    v_card_number := NULL;
    v_phone := NULL;
  ELSE
    v_card_number := p_datos ->> 'card_number';
    v_phone := p_datos ->> 'phone';
    IF v_card_number IS NULL OR v_card_number !~ '^[0-9]{16}$' THEN
      RAISE EXCEPTION 'card_number must be exactly 16 digits' USING ERRCODE = '22023';
    END IF;
    -- (190) The phone is optional: the owner records a card the customer gave without its phone, and closes the
    -- remesa manually (crm_cerrar_operacion_manual). A given phone is still validated; the remesa stays incomplete
    -- (crm_beneficiarios_completos) so a normal delivery still needs it.
    v_phone := nullif(btrim(coalesce(v_phone, '')), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_name := p_datos ->> 'name';
    v_zelle_account := NULL;
  END IF;

  SELECT coalesce(max(position), 0) + 1 INTO v_next_position
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id;

  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index
  ) VALUES (
    p_operation_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_next_position, 'vigente', 'admin_addition', v_next_block_index
  ) RETURNING id INTO v_new_id;

  -- Lock beneficiaries on this operation so automation cannot overwrite or
  -- delete the row a human just added — same lock crm_corregir_beneficiario
  -- and crm_reasignar_beneficiario place (098), honored by
  -- cerebro_sync_beneficiarios' early return (also 098).
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,card_number,phone,zelle_account,delivery_method,amount,currency',
          'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);

  RETURN jsonb_build_object(
    'id', v_new_id,
    'complete', crm_beneficiarios_completos(p_operation_id)
  );
END $function$;

-- ---------------------------------------------------------------------
-- crm_set_calculator_rates
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_set_calculator_rates(p_account_id uuid, p_rates jsonb, p_expected_version_id uuid DEFAULT NULL::uuid)
 RETURNS calculator_rate_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_current  calculator_rate_versions;
  v_new      calculator_rate_versions;
  v_key      text;
  v_value    numeric;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to set calculator rates' USING ERRCODE = '42501';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd',
                     'recarga_costo_usdt', 'saldo_costo_usdt', 'zelle_sell_gyd', 'zelle_sell_gyd_1000', 'zelle_sell_gyd_2000') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(p_rates -> v_key) NOT IN ('number', 'null') THEN
      RAISE EXCEPTION 'rate % must be a number or null', v_key USING ERRCODE = '22023';
    END IF;

    v_value := (p_rates ->> v_key)::numeric;
    IF v_value IS NOT NULL AND (v_value <= 0 OR v_value >= 1e9) THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Lock the account's rate history so two concurrent admins cannot both
  -- read the same "current" and both append on top of it.
  PERFORM 1 FROM accounts WHERE id = p_account_id FOR UPDATE;

  v_current := calculator_rates_vigentes(p_account_id);

  IF p_expected_version_id IS NOT NULL
     AND p_expected_version_id IS DISTINCT FROM v_current.id THEN
    RAISE EXCEPTION 'calculator rates changed concurrently, reload and retry'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO calculator_rate_versions (
    account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, efectivo_usd_gyd,
    recarga_costo_usdt, saldo_costo_usdt, zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000, set_by
  ) VALUES (
    p_account_id,
    CASE WHEN p_rates ? 'cup_global_rate'
         THEN (p_rates ->> 'cup_global_rate')::numeric ELSE v_current.cup_global_rate END,
    CASE WHEN p_rates ? 'usdt_buy_gyd'
         THEN (p_rates ->> 'usdt_buy_gyd')::numeric ELSE v_current.usdt_buy_gyd END,
    CASE WHEN p_rates ? 'usdt_sell_gyd'
         THEN (p_rates ->> 'usdt_sell_gyd')::numeric ELSE v_current.usdt_sell_gyd END,
    CASE WHEN p_rates ? 'usdt_sell_cup'
         THEN (p_rates ->> 'usdt_sell_cup')::numeric ELSE v_current.usdt_sell_cup END,
    CASE WHEN p_rates ? 'efectivo_usd_gyd'
         THEN (p_rates ->> 'efectivo_usd_gyd')::numeric ELSE v_current.efectivo_usd_gyd END,
    -- (198) The cost of one recharge in USDT.
    CASE WHEN p_rates ? 'recarga_costo_usdt'
         THEN (p_rates ->> 'recarga_costo_usdt')::numeric ELSE v_current.recarga_costo_usdt END,
    -- (223) The cost of one package of mobile balance in USDT.
    CASE WHEN p_rates ? 'saldo_costo_usdt'
         THEN (p_rates ->> 'saldo_costo_usdt')::numeric ELSE v_current.saldo_costo_usdt END,
    -- (216) The Zelle sale price of each tier.
    CASE WHEN p_rates ? 'zelle_sell_gyd'
         THEN (p_rates ->> 'zelle_sell_gyd')::numeric ELSE v_current.zelle_sell_gyd END,
    CASE WHEN p_rates ? 'zelle_sell_gyd_1000'
         THEN (p_rates ->> 'zelle_sell_gyd_1000')::numeric ELSE v_current.zelle_sell_gyd_1000 END,
    CASE WHEN p_rates ? 'zelle_sell_gyd_2000'
         THEN (p_rates ->> 'zelle_sell_gyd_2000')::numeric ELSE v_current.zelle_sell_gyd_2000 END,
    auth.uid()
  )
  RETURNING * INTO v_new;

  RETURN v_new;
END;
$function$;

-- ---------------------------------------------------------------------
-- calculator_service_for_operation
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculator_service_for_operation(p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE lower(coalesce(p_delivery_method, ''))
           WHEN 'cuban_card'            THEN 'CUP'
           WHEN 'multiple_distribution' THEN 'CUP'
           WHEN 'zelle'                 THEN 'ZELLE'
           WHEN 'clasica'               THEN 'CLASICA'
           WHEN 'tropical'              THEN 'TROPICAL'
           -- (193) Cash dollars delivered in Cuba: their own service, priced at the cash sale rate.
           WHEN 'efectivo_usd'          THEN 'EFECTIVO'
           -- (199) A beneficiary row of a recharge (one Cuban number per recharge).
           WHEN 'recarga'               THEN 'RECARGA'
           -- (209) A combo (its beneficiary rows are typed 'combo' and so is its service_type).
           WHEN 'combo'                 THEN 'COMBO'
           -- (213) A visa extension (no beneficiary rows: its service_type is the only signal).
           WHEN 'visa'                  THEN 'VISA'
           -- (223) A mobile balance (service_type; its recipient row is typed 'recarga' and maps to RECARGA on its own).
           WHEN 'saldo'                 THEN 'SALDO_MOVIL'
           ELSE NULL
         END;
$function$;

-- ---------------------------------------------------------------------
-- calculator_resolve_operation_service
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculator_resolve_operation_service(p_operation_id uuid, p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
           -- (199) A recharge is priced as RECARGA whatever its rows say (even with no number yet).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'recarga' THEN 'RECARGA'
           -- (209) A combo is priced as COMBO whatever its rows say.
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'combo' THEN 'COMBO'
           -- (213) A visa is priced as VISA (it has no rows at all).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'visa' THEN 'VISA'
           -- (223) A mobile balance is priced as SALDO_MOVIL whatever its rows say (its phone row is typed 'recarga').
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'saldo' THEN 'SALDO_MOVIL'
           WHEN NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) THEN calculator_service_for_operation(p_delivery_method)
           WHEN (
             SELECT count(DISTINCT b.beneficiary_type)
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) = 1 THEN calculator_service_for_operation((
             SELECT b.beneficiary_type
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
              LIMIT 1
           ))
           ELSE NULL
         END;
$function$;

-- ---------------------------------------------------------------------
-- calculator_missing_rates
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculator_missing_rates(p_service text, p_rates calculator_rate_versions)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_service
    WHEN 'CUP' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.cup_global_rate IS NULL THEN 'cupGlobalRate' END,
        CASE WHEN p_rates.usdt_sell_cup   IS NULL THEN 'usdtSellCup'   END,
        CASE WHEN p_rates.usdt_buy_gyd    IS NULL THEN 'usdtBuyGyd'    END
      ], NULL)
    -- (199) A recharge: its USDT cost and the USDT buy rate (its price comes from the deposit, see the feed).
    WHEN 'RECARGA' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.recarga_costo_usdt IS NULL THEN 'recargaCostoUsdt' END,
        CASE WHEN p_rates.usdt_buy_gyd       IS NULL THEN 'usdtBuyGyd'       END
      ], NULL)
    -- (223) A mobile balance: its USDT cost per package and the USDT buy rate (its price comes from the config, see the feed).
    WHEN 'SALDO_MOVIL' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.saldo_costo_usdt IS NULL THEN 'saldoCostoUsdt' END,
        CASE WHEN p_rates.usdt_buy_gyd     IS NULL THEN 'usdtBuyGyd'     END
      ], NULL)
    -- (209) A combo depends on no rate: its cost is entered on the operation (the feed names comboCosto).
    WHEN 'COMBO' THEN ARRAY[]::text[]
    -- (213) A visa depends on no rate either: 5,000 GYD per person, all profit (owner 2026-10-04).
    WHEN 'VISA' THEN ARRAY[]::text[]
    -- (193) Cash: the shared buy rate and the cash sale rate (efectivo_usd_gyd), not the Zelle sale rate.
    WHEN 'EFECTIVO' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd     IS NULL THEN 'usdtBuyGyd'     END,
        CASE WHEN p_rates.efectivo_usd_gyd IS NULL THEN 'efectivoUsdGyd' END
      ], NULL)
    ELSE
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd  IS NULL THEN 'usdtBuyGyd'  END,
        CASE WHEN p_rates.usdt_sell_gyd IS NULL THEN 'usdtSellGyd' END
      ], NULL)
  END;
$function$;

-- ---------------------------------------------------------------------
-- calculator_feed_operation
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculator_feed_operation(p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_sell      numeric;
  v_zrate     numeric;
  v_part      record;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
  v_first_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  IF v_op.quoted_source_amount IS NULL OR v_op.quoted_source_amount <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates := calculator_rates_vigentes(v_op.account_id);
  -- (215) The Zelle sale rate is the tier of the deposit's TOTAL (also for a part of a split deposit).
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_op(v_op.id, v_op.quoted_source_amount) z;

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    -- (223) a mobile balance whose deposit is not a whole number of packages cannot be priced: no silent rounding
    IF v_part.service = 'SALDO_MOVIL' AND cerebro_saldo_paquetes(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['saldoPaquetes'];
    END IF;
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN 'REC'
                        WHEN v_part.service IN ('COMBO', 'VISA') THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        -- (223) a mobile balance sells at the package price (cerebro_saldo_precio)
                        WHEN v_part.service = 'SALDO_MOVIL' THEN cerebro_saldo_precio()
                        -- (215) Zelle: tiered (still pending while the calculator has no sell rate); Clasica, Tropical and the rest keep usdt_sell_gyd
                        WHEN v_part.service = 'ZELLE' AND v_rates.usdt_sell_gyd IS NOT NULL THEN coalesce(v_zrate, v_rates.usdt_sell_gyd)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_part.service = 'COMBO' THEN
      -- (209) facturado = the verified deposit (GYD), invertido = the cost entered on the operation.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := v_op.combo_costo_gyd;
      END IF;
    ELSIF v_part.service = 'VISA' THEN
      -- (213) facturado = the verified deposit (GYD), invertido = 0 (owner: all of it is profit). No rate, never pending.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := 0;
      END IF;
    ELSIF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_sell);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_sell);
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line)
                          THEN v_amount * v_rates.recarga_costo_usdt * v_rates.usdt_buy_gyd
                          -- (223) packages x USDT cost per package x USDT buy rate
                          WHEN v_part.service = 'SALDO_MOVIL' THEN v_amount * v_rates.saldo_costo_usdt * v_rates.usdt_buy_gyd
                          ELSE calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd) END;
    END IF;

    IF v_basis IS NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_missing := ARRAY['beneficiaryAmounts'];
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
      v_amount := v_part.placeholder_amount;
      v_facturado := NULL;
      v_invertido := NULL;
      IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_missing := ARRAY['beneficiaryAmounts'];
      END IF;
    END IF;

    -- (209) The cost of a combo is entered by hand and can change. Completed lines are append-only (149), so a live COMBO
    -- line whose figures differ is VOIDED here (figures untouched) and the upsert below revives that row with the new
    -- ones, the way a reverted-then-completed operation is re-fed. Identical figures: nothing is touched (idempotent).
    IF v_part.service = 'COMBO' THEN
      UPDATE remittance_calculator_entries e
         SET status = 'void', voided_at = clock_timestamp(), void_reason = 'combo cost or deposit changed; re-fed'
       WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
         AND e.service = 'COMBO' AND e.status <> 'void'
         AND (e.status IS DISTINCT FROM CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END
              OR e.amount IS DISTINCT FROM v_amount OR e.facturado_gyd IS DISTINCT FROM v_facturado
              OR e.invertido_gyd IS DISTINCT FROM v_invertido OR e.basis_gyd IS DISTINCT FROM v_basis);
    END IF;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, customer_name,
      service, amount, amount_currency, basis_gyd,
      cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
      facturado_gyd, invertido_gyd, retorno_gyd,
      missing_inputs, delivery_mode, actor_user_id, completed_at, cost_gyd, sale_gyd
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      -- (199) A RECARGA line reads like a manual "rec promo" one: cup_rate = USDT rate, cost_gyd = USDT cost, sale_gyd = price.
      -- (209) A COMBO line snapshots no rate (it does not depend on them). (213) Nor does a VISA line.
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.cup_global_rate END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL
           WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'SALDO_MOVIL' THEN v_rates.saldo_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd
           WHEN v_part.service = 'VISA' THEN 0 END,
      CASE WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_sell
           WHEN v_part.service IN ('COMBO', 'VISA') THEN v_facturado END
    )
    ON CONFLICT (account_id, operation_id, service) WHERE source = 'completed_operation'
    DO UPDATE SET
      status          = EXCLUDED.status,
      entry_date      = EXCLUDED.entry_date,
      customer_name   = EXCLUDED.customer_name,
      amount          = EXCLUDED.amount,
      amount_currency = EXCLUDED.amount_currency,
      basis_gyd       = EXCLUDED.basis_gyd,
      cup_global_rate = EXCLUDED.cup_global_rate,
      cup_rate        = EXCLUDED.cup_rate,
      usdt_buy_gyd    = EXCLUDED.usdt_buy_gyd,
      usdt_sell_gyd   = EXCLUDED.usdt_sell_gyd,
      rate_version_id = EXCLUDED.rate_version_id,
      facturado_gyd   = EXCLUDED.facturado_gyd,
      invertido_gyd   = EXCLUDED.invertido_gyd,
      retorno_gyd     = EXCLUDED.retorno_gyd,
      missing_inputs  = EXCLUDED.missing_inputs,
      delivery_mode   = EXCLUDED.delivery_mode,
      actor_user_id   = EXCLUDED.actor_user_id,
      completed_at    = EXCLUDED.completed_at,
      cost_gyd        = EXCLUDED.cost_gyd,
      sale_gyd        = EXCLUDED.sale_gyd,
      voided_at       = NULL,
      void_reason     = NULL
    WHERE remittance_calculator_entries.status = 'void'
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_resolve_pending_entry
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_resolve_pending_entry(p_entry_id uuid, p_rates jsonb, p_reason text)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry     remittance_calculator_entries;
  v_before    jsonb;
  v_basis     numeric;
  v_cup_glob  numeric;
  v_cup_rate  numeric;
  v_buy       numeric;
  v_sell      numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_missing   text[];
  v_key       text;
  v_value     numeric;
  v_zrate     numeric;
  v_cost      numeric;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to resolve ledger entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.status <> 'verified_pending' THEN
    RAISE EXCEPTION 'only a pending entry can be resolved' USING ERRCODE = '22023';
  END IF;

  -- (209) A COMBO line is priced by the combo's cost (crm_set_combo_costo, panel), never by rates.
  IF v_entry.service = 'COMBO' THEN
    RAISE EXCEPTION 'a combo line is resolved by entering the combo cost in the panel, not with rates' USING ERRCODE = '22023';
  END IF;

  -- (213) A VISA line never needs rates (facturado = the deposit, invertido = 0): nothing to resolve with them.
  IF v_entry.service = 'VISA' THEN
    RAISE EXCEPTION 'a visa line needs no rates: it is priced by its deposit' USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd',
                     'recarga_costo_usdt', 'saldo_costo_usdt') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_rates -> v_key) <> 'number' THEN
      RAISE EXCEPTION 'rate % must be a number', v_key USING ERRCODE = '22023';
    END IF;
    v_value := (p_rates ->> v_key)::numeric;
    IF v_value <= 0 OR v_value >= 1e9 THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_before := to_jsonb(v_entry);

  -- (223) A RECARGA or SALDO_MOVIL line is priced by its own rule, never as a USD service (it used to ask for a Zelle-style
  -- sale rate and price floor(deposit / rate) units): units = deposit / its price (the recharge price the deposit pays,
  -- or the package price), facturado = units x price, invertido = units x cost per unit x USDT buy rate. What the
  -- line recorded wins (coalesce); the cost and the buy rate come from the payload. A saldo deposit that is not a
  -- whole number of packages (and a recharge deposit matching no price) cannot be resolved with rates: a person
  -- fixes the deposit and re-feeds the operation.
  IF v_entry.service IN ('RECARGA', 'SALDO_MOVIL') THEN
    v_buy   := coalesce(v_entry.usdt_buy_gyd, (p_rates ->> 'usdt_buy_gyd')::numeric);
    v_cost  := coalesce(v_entry.cost_gyd,
                        CASE WHEN v_entry.service = 'RECARGA' THEN (p_rates ->> 'recarga_costo_usdt')::numeric
                             ELSE (p_rates ->> 'saldo_costo_usdt')::numeric END);
    v_basis := coalesce(v_entry.basis_gyd, (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_entry.operation_id));
    v_sell  := CASE WHEN v_entry.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis) ELSE cerebro_saldo_precio() END;
    IF v_entry.service = 'SALDO_MOVIL' AND cerebro_saldo_paquetes(v_basis) IS NULL THEN
      RAISE EXCEPTION 'this saldo line is not a whole number of packages: fix the deposit and re-feed the operation' USING ERRCODE = '22023';
    END IF;
    IF v_entry.service = 'RECARGA' AND v_sell IS NULL THEN
      RAISE EXCEPTION 'this recarga line matches no recharge price: fix the deposit and re-feed the operation' USING ERRCODE = '22023';
    END IF;
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cost IS NULL THEN CASE WHEN v_entry.service = 'RECARGA' THEN 'recargaCostoUsdt' ELSE 'saldoCostoUsdt' END END,
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd' END
    ], NULL);
    IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
      RAISE EXCEPTION 'a % line still needs: %', CASE WHEN v_entry.service = 'RECARGA' THEN 'recarga' ELSE 'saldo' END,
        array_to_string(v_missing, ', ') USING ERRCODE = '22023';
    END IF;
    v_amount    := floor(v_basis / v_sell);
    v_facturado := v_amount * v_sell;
    v_invertido := v_amount * v_cost * v_buy;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
    END IF;
    UPDATE remittance_calculator_entries
       SET status          = 'completed',
           amount          = v_amount,
           cup_rate        = v_buy,
           usdt_buy_gyd    = v_buy,
           usdt_sell_gyd   = v_sell,
           facturado_gyd   = v_facturado,
           invertido_gyd   = v_invertido,
           retorno_gyd     = v_facturado - v_invertido,
           cost_gyd        = v_cost,
           sale_gyd        = v_sell,
           missing_inputs  = NULL
     WHERE id = p_entry_id
     RETURNING * INTO v_entry;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
    VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
            'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
            v_before, to_jsonb(v_entry));
    RETURN v_entry;
  END IF;

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  -- (193) A cash line sells at the cash rate.
  v_sell     := coalesce(v_entry.usdt_sell_gyd,
                         CASE WHEN v_entry.service = 'EFECTIVO' THEN (p_rates ->> 'efectivo_usd_gyd')::numeric
                              ELSE (p_rates ->> 'usdt_sell_gyd')::numeric END);

  -- (215) A ZELLE line whose operation's deposit total reaches a tier above the base one sells at that tier, not at
  -- the rate the payload carries. A deposit in the base tier keeps the rate the admin entered, and a line still
  -- missing its sell rate keeps asking for it (the required-rate check below is unchanged).
  IF v_entry.service = 'ZELLE' AND v_sell IS NOT NULL THEN
    SELECT z.tasa INTO v_zrate
      FROM remittance_operations o, cerebro_zelle_cotizar_op(o.id, o.quoted_source_amount) z
     WHERE o.id = v_entry.operation_id;
    IF v_zrate IS NOT NULL AND v_zrate < cerebro_tasa_zelle(50) THEN
      v_sell := coalesce(v_entry.usdt_sell_gyd, v_zrate);
    END IF;
  END IF;

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN CASE WHEN v_entry.service = 'EFECTIVO' THEN 'efectivoUsdGyd' ELSE 'usdtSellGyd' END END
    ], NULL);
  END IF;

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'still missing required rate(s): %', array_to_string(v_missing, ', ')
      USING ERRCODE = '22023';
  END IF;

  -- The deposit is re-read from the operation rather than trusted from the
  -- pending row, whose `amount` column held the deposit as a placeholder.
  -- (142) A line of a MIXED remesa is priced on its own share of the
  -- deposit (basis_gyd), never on the whole deposit.
  IF v_entry.basis_gyd IS NOT NULL THEN
    v_basis := v_entry.basis_gyd;
  ELSIF EXISTS (SELECT 1 FROM remittance_calculator_entries o
                 WHERE o.account_id = v_entry.account_id
                   AND o.operation_id = v_entry.operation_id
                   AND o.source = 'completed_operation'
                   AND o.service <> v_entry.service
                   AND o.status <> 'void') THEN
    RAISE EXCEPTION 'this line belongs to a mixed remesa whose share is unknown: fix the beneficiary amounts and re-feed the operation'
      USING ERRCODE = '22023';
  ELSE
    SELECT quoted_source_amount INTO v_basis
      FROM remittance_operations WHERE id = v_entry.operation_id;
  END IF;

  v_amount    := calculator_amount_from_basis(v_entry.service, v_basis, v_cup_glob, v_sell);
  v_facturado := calculator_facturado(v_entry.service, v_amount, v_cup_glob, v_sell);
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_calculator_entries
     SET status          = 'completed',
         amount          = v_amount,
         cup_global_rate = v_cup_glob,
         cup_rate        = v_cup_rate,
         usdt_buy_gyd    = v_buy,
         usdt_sell_gyd   = v_sell,
         facturado_gyd   = v_facturado,
         invertido_gyd   = v_invertido,
         retorno_gyd     = v_facturado - v_invertido,
         missing_inputs  = NULL
   WHERE id = p_entry_id
   RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
          v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

-- ---------------------------------------------------------------------
-- cerebro_escribir_bloque_beneficiario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      uuid := p_op;
  v_bi      integer;
  v_reparto boolean;
  v_zelle   integer;
  v_locked  boolean;
  v_account uuid;
BEGIN
  -- (210) A combo's recipients are written only by crm_registrar_destinatario_combo: this remesa writer (typed numbers,
  -- the remesa tools) neither writes on a combo nor opens a remesa next to an open combo. Owner test 2026-10-04: typed
  -- phones became 'cuban_card' generations on the combo and its recipients turned 'reemplazado'.
  -- (223) Nor ON a mobile balance (its one phone recipient is written from the panel only): a typed card is a remesa.
  -- (213) Never ON a visa (it has no recipients at all) nor on a combo past collecting its recipients (its deposit
  -- arrived): the typed data is a new remesa, opened next to it. Only a combo still collecting keeps the numbers (210).
  IF v_op IS NOT NULL AND EXISTS (SELECT 1 FROM remittance_operations o WHERE o.id = v_op
                                   AND (o.service_type IN ('visa', 'saldo')
                                        OR (o.service_type = 'combo' AND o.status <> 'collecting_information'))) THEN
    v_op := cerebro_crear_operacion(p_conv);
  ELSIF v_op IS NULL THEN
    SELECT o.id INTO v_op FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status = 'collecting_information'
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_op IS NOT NULL THEN RETURN v_op; END IF;
    v_op := cerebro_crear_operacion(p_conv);
  END IF;
  IF (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_op) = 'combo' THEN
    RETURN v_op;
  END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account
    FROM remittance_operations WHERE id = v_op;
  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN v_op;
  END IF;

  SELECT coalesce(max(b.block_index), 0) + 1 INTO v_bi FROM remittance_beneficiaries b WHERE b.operation_id = v_op;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone,
                                        zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular, p.cuenta_zelle, p.monto, p.moneda, p.posicion, v_bi,
         'notes_parse', 'vigente'
    FROM cerebro_parsear_beneficiarios(p_bloque) p;

  -- (175) The newest generation is a reparto between cards: the latest Zelle stays vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_bi
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND block_index < v_bi;
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_bi AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_zelle AND beneficiary_type = 'zelle' AND status <> 'vigente';

  RETURN v_op;
END $function$;

-- ---------------------------------------------------------------------
-- cerebro_resolver_operacion_beneficiario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_resolver_operacion_beneficiario(p_conversation_id uuid, p_estados text[], p_cuenta text)
 RETURNS TABLE(resultado text, operation_id uuid, candidatas integer, metodo text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_total     integer;
  v_unica     uuid;
  v_cuenta    text;
  v_es_correo boolean;
  v_es_tarjeta boolean;
  v_usd       numeric := crm_tasa_vigente('usd');
  v_cup       numeric := crm_tasa_vigente('gyd');
  v_desde     timestamptz;
  v_anchor_i  integer;
  v_anchor_t  timestamptz;
  v_m         record;
  v_num       text[];
  v_n         numeric;
  v_hit       uuid;
  v_hits      integer;
  v_cand      boolean;
  v_newest    uuid;
BEGIN
  -- (213) A visa and a combo are never the remesa target (the writers refuse them): they are not candidates here.
  -- (223) Nor is a mobile balance.
  -- 0/1 open operation: identical to cerebro_resolver_operacion.
  SELECT count(*) INTO v_total FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados));
  IF v_total = 0 THEN
    RETURN QUERY SELECT 'ninguna'::text, NULL::uuid, 0, 'ninguna'::text; RETURN;
  ELSIF v_total = 1 THEN
    SELECT o.id INTO v_unica FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
       AND (p_estados IS NULL OR o.status = ANY(p_estados));
    RETURN QUERY SELECT 'unica'::text, v_unica, 1, 'unica'::text; RETURN;
  END IF;

  -- Several: normalize the account the node is about to register.
  v_cuenta := lower(regexp_replace(coalesce(p_cuenta,''), '\s', '', 'g'));
  v_es_correo := position('@' in v_cuenta) > 0;
  IF NOT v_es_correo THEN
    v_cuenta := regexp_replace(v_cuenta, '\D', '', 'g');
    IF length(v_cuenta) = 11 AND left(v_cuenta, 1) = '1' THEN v_cuenta := substr(v_cuenta, 2); END IF;
  END IF;
  v_es_tarjeta := NOT v_es_correo AND length(v_cuenta) = 16;
  IF v_cuenta = '' THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_cuenta'::text; RETURN;
  END IF;

  -- The customer's messages since the oldest open operation (minus 3 h), in
  -- order, normalized, with their position.
  SELECT min(o.created_at) - interval '3 hours' INTO v_desde FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled');

  -- 1. Reparto guard.
  IF EXISTS (SELECT 1 FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) WHERE txt ~ '(personas|a cada|repart|una de las|mexico|méxico)') THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'reparto'::text; RETURN;
  END IF;

  -- 3. Anchor: the MOST RECENT message that contains the account (133); else latest image.
  --    A customer who reuses an account for a new remesa writes it again: the first time it
  --    appeared belongs to the OLD remesa (1727ef31, de846b30).
  SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
   WHERE (v_es_correo AND replace(b.txt, ' ', '') LIKE '%' || v_cuenta || '%')
      OR (NOT v_es_correo AND regexp_replace(b.txt, '\D', '', 'g') LIKE '%' || v_cuenta || '%')
   ORDER BY b.i DESC LIMIT 1;
  IF v_anchor_i IS NULL THEN
    SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b WHERE b.tipo = 'image' ORDER BY b.i DESC LIMIT 1;
  END IF;
  IF v_anchor_i IS NULL THEN v_anchor_t := now(); END IF;

  -- 4. Amount written next to the account.
  IF v_anchor_i IS NOT NULL THEN
    FOR v_m IN
      SELECT b.* FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
       WHERE b.tipo = 'text' AND abs(b.i - v_anchor_i) <= 3
         AND abs(extract(epoch FROM b.t - v_anchor_t)) <= 180
       ORDER BY abs(b.i - v_anchor_i), b.i
    LOOP
      FOR v_num IN
        SELECT regexp_matches(v_m.txt,
          '(?:^|[^0-9.,])([0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]{2,6})(?![0-9])\s*(usd|zelle|d[oó]lar(?:es)?|\$|cup|pesos)?', 'g')
      LOOP
        IF v_num[2] IS NULL AND btrim(v_m.txt) <> btrim(v_num[1])
           AND v_m.txt !~ '(zelle|usd|d[oó]lar|cup|tarjeta|\$)' THEN
          CONTINUE;
        END IF;
        v_n := replace(replace(v_num[1], '.', ''), ',', '')::numeric;
        SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
         WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
           AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
           AND (p_estados IS NULL OR o.status = ANY(p_estados))
           -- (215) A Zelle account is paired by the tiered USD of the deposit; a card (Clasica, Tropical) by the single rate.
           AND ((NOT v_es_tarjeta AND (SELECT z.usd FROM cerebro_zelle_cotizar_op(o.id, o.quoted_source_amount) z) = v_n)
                OR (v_es_tarjeta AND v_usd > 0 AND floor(o.quoted_source_amount / v_usd) = v_n)
                OR (v_es_tarjeta AND v_cup > 0 AND round(o.quoted_source_amount * v_cup) = v_n));
        IF v_hits = 1 THEN
          SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
              OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                          AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                               OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
            INTO v_cand;
          IF v_cand THEN
            RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'monto'::text; RETURN;
          END IF;
          RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'monto_apunta_a_otra'::text; RETURN;
        END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- 5. Proximity: exactly one open remesa created within 5 minutes.
  SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
     AND abs(extract(epoch FROM o.created_at - v_anchor_t)) <= 300;
  IF v_hits = 1 THEN
    SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
        OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                    AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                         OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
      INTO v_cand;
    IF v_cand THEN
      RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'cercania'::text; RETURN;
    END IF;
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'cercania_apunta_a_otra'::text; RETURN;
  END IF;

  -- 6. Rule C.
  SELECT o.id INTO v_newest FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
   ORDER BY o.created_at DESC LIMIT 1;
  IF v_newest IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_newest AND rb.status = 'vigente')
     AND NOT EXISTS (
       SELECT 1 FROM remittance_operations o
        WHERE o.conversation_id = p_conversation_id AND o.id <> v_newest
          AND o.service_type NOT IN ('visa', 'combo', 'saldo') AND o.status NOT IN ('completed','cancelled')
          AND (p_estados IS NULL OR o.status = ANY(p_estados))
          AND o.created_at >= now() - interval '24 hours'
          AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = o.id AND rb.status = 'vigente'))
  THEN
    RETURN QUERY SELECT 'unica'::text, v_newest, v_total, 'regla_c'::text; RETURN;
  END IF;

  RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_evidencia'::text;
END $function$;

-- ---------------------------------------------------------------------
-- cerebro_avisar_envios_sin_beneficiario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_avisar_envios_sin_beneficiario(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(sin_destino integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_silencio int;
  v_ahora_gy timestamp; v_desde time; v_hasta time;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_min      := COALESCE(p_minutos,     NULLIF(cerebro_config_get('sin_beneficiario_min'), '')::int, 30);
  v_repetir  := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('sin_beneficiario_repetir_min'), '')::int, 120);
  v_silencio := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_silencio_humano_min'), '')::int, 20);
  v_desde    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_desde'), '')::time, (SELECT abre FROM cerebro_horario()));
  v_hasta    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_hasta'), '')::time, (SELECT cierra FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < v_desde OR v_ahora_gy::time >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT op.id, op.deal_id, op.account_id, op.contact_id, op.conversation_id,
           op.quoted_source_amount AS value, op.source_currency AS currency,
           c.name, c.phone, dep.dinero_dentro
      FROM remittance_operations op
      JOIN conversations v ON v.id = op.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      CROSS JOIN LATERAL (
        SELECT max(m.consumido_en) AS dinero_dentro
          FROM depositos_mmg m
         WHERE m.operation_id = op.id
           AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
     -- (213) a visa has no recipient by design. (223) A mobile balance is not a card shipment: its number is written from the
     -- panel, and this alarm's notice asks the customer for a card.
     WHERE COALESCE(op.service_type, 'remesa') NOT IN ('recarga', 'visa', 'saldo')
       AND op.status IN ('deposit_verification', 'ready_to_transfer')
       AND dep.dinero_dentro IS NOT NULL
       AND dep.dinero_dentro < now() - make_interval(mins => v_min)
       AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                        WHERE b.operation_id = op.id AND b.status = 'vigente')
       AND NOT EXISTS (SELECT 1 FROM messages m
                        WHERE m.conversation_id = op.conversation_id
                          AND m.sender_type = 'agent'
                          AND NOT COALESCE(m.ai_generated, false)
                          AND m.created_at > now() - make_interval(mins => v_silencio))
       AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                        WHERE a.clave = 'sin_beneficiario:' || coalesce(op.deal_id, op.id)::text
                          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) >= 86400
        THEN round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 86400)::text || ' dias'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 3600)::text || ' h' END;

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'envio_sin_beneficiario', r.conversation_id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ': '
             || rtrim(trim(to_char(r.value, 'FM999,999,999,990.99')), '.') || ' ' || r.currency
             || ' dentro y SIN DESTINATARIO, lleva ' || v_espera,
           'El deposito esta verificado y consumido, pero el envio NO tiene a quien '
             || 'transferirle: ni tarjeta, ni celular, ni cuenta Zelle. El envio sigue '
             || 'abierto y ahi se queda. '
             || 'OJO: el bot puede haberle dicho al cliente que sus datos quedaban '
             || 'anotados sin que se anotara nada - abra el chat y compruebe lo que se '
             || 'le prometio antes de escribirle. Si el cliente ya dio los datos, el '
             || 'arreglo es registrar el beneficiario por la via estructurada: se '
             || 'escribe la fila de remittance_beneficiaries (las funciones de la '
             || 'migracion 162, las mismas que usa el bot y el panel), no el bloque '
             || 'BENEFICIARIO en las notas del deal.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('sin_beneficiario:' || coalesce(r.deal_id, r.id)::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;
