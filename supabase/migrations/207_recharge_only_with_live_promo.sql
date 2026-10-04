-- =====================================================================
-- 207 — A recharge opens only with a running or a confirmed upcoming ETECSA promo
--
-- odd/tasks/recharge-only-with-live-promo.md. Owner test on staging, 2026-10-04: with no promo running, the agent's
-- tool (204, p_abrir) opened a recharge with no promo check, and an open recharge makes the Decisor ask for the number.
-- Owner, same day: the admins often take the numbers before a confirmed promo starts; the customer pays then or on
-- the day, it varies.
--   * crm_registrar_numeros_recarga: with no promo running and none confirmed ahead, it opens nothing, saves nothing,
--     and says to offer an operator. With a confirmed upcoming promo the recharge opens and its reply says it is
--     booked for the start date (pay now or that day; never done before it). An open recharge keeps working.
--   * cerebro_servicio_get: the upcoming-promo text lets the bot book it now, on the same terms.
-- Both bodies are otherwise byte-for-byte the previous ones (see the ROLLBACK).
-- Assertion: supabase/staging/assertions/recharge-only-with-live-promo.sql. Rollback: ROLLBACK-207-recharge-only-with-live-promo.sql.
-- =====================================================================
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
    -- (207) A new recharge opens only with a promo running or a confirmed one ahead (booked for its start date): with
    -- neither, the bot was asking for a number for a recharge nobody could do. Nothing is saved then.
    IF NOT EXISTS (SELECT 1 FROM cerebro_promo_vigente()) AND NOT EXISTS (SELECT 1 FROM cerebro_promo_proxima()) THEN
      RETURN 'NO HAY PROMOCION DE ETECSA, ni vigente ni anunciada: no se abre ninguna recarga y no se guarda ningun numero. '
             || 'PROHIBIDO pedir el numero de Cuba. Ofrece pasar con un operador.';
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
                 ELSE ' FALTA ' || (v_need - v_have) || ' numero(s) de recarga (son ' || v_need || ' recargas, un numero por recarga). Pideselo al cliente.' END
         -- (207) Booked ahead of a confirmed promo: what to tell the customer about when it is done and paid.
         || CASE WHEN EXISTS (SELECT 1 FROM cerebro_promo_vigente()) THEN ''
                 ELSE COALESCE((SELECT format(' LA PROMOCION AUN NO EMPIEZA: la recarga queda ANOTADA PARA EL %s y se hace ese dia. '
                                              || 'Si el cliente quiere pagar ya, puede; si no, paga ese dia: no le exijas el pago ahora. '
                                              || 'PROHIBIDO decir que se hace hoy o en minutos.', to_char(p.vigente_desde, 'DD/MM'))
                                  FROM cerebro_promo_proxima() p), '') END;
END $function$
;
CREATE OR REPLACE FUNCTION public.cerebro_servicio_get(p_busqueda text DEFAULT NULL::text)
 RETURNS TABLE(nombre text, hechos text, enlace text, requiere_humano boolean, notas_internas text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.nombre,
         CASE WHEN s.clave = 'recargas' THEN
           s.hechos || E'\n' || COALESCE(
             -- 1) Promo vigente HOY: se puede cotizar y cobrar
             (SELECT format('PROMOCION VIGENTE HOY: se recarga el minimo de %s CUP y el cliente recibe x%s. Precio para el cliente: %s GYD. Valida hasta el %s.',
                            v.min_cup, v.multiplicador, v.precio_gyd, to_char(v.vigente_hasta,'DD/MM'))
                FROM cerebro_promo_vigente() v),
             -- 2) Promo CONFIRMADA que aun no empieza: se informa, NO se vende
             (SELECT format('PROXIMA PROMOCION, EMPIEZA EL %s (en %s dias) y dura hasta el %s: se recargara el minimo de %s CUP y el cliente recibira x%s, precio %s GYD. HOY NO SE PUEDE HACER TODAVIA. Di la fecha y el precio si preguntan. Si el cliente la quiere, se puede dejar ANOTADA desde ya: toma el numero de Cuba (registrar_numeros_recarga) y aclarale que se hace ese dia. Puede pagar ahora o ese dia, como prefiera: no le exijas el pago ahora. PROHIBIDO decir que se hace hoy o en minutos.',
                            to_char(p.vigente_desde,'DD/MM'), p.dias_para, to_char(p.vigente_hasta,'DD/MM'),
                            p.min_cup, p.multiplicador, p.precio_gyd)
                FROM cerebro_promo_proxima() p),
             -- 3) Nada
             'HOY NO HAY PROMOCION CONFIRMADA. No cotices recargas: ofrece pasar con un operador.')
         -- (188) The cash text carries the live rates instead of numbers typed in it.
         WHEN s.clave = 'efectivo_usd' THEN
           replace(replace(replace(s.hechos,
             '{tasa_efectivo}', trim(to_char(crm_tasa_vigente('efectivo'), 'FM999,999,990.##'))),
             '{minimo_efectivo_gyd}', trim(to_char(cerebro_minimo_efectivo_gyd(), 'FM999,999,990'))),
             '{tasa_usd}', trim(to_char(crm_tasa_vigente('usd'), 'FM999,999,990.##')))
         ELSE s.hechos END AS hechos,
         s.enlace,
         CASE WHEN s.clave = 'recargas' AND EXISTS (SELECT 1 FROM cerebro_promo_vigente())
              THEN false ELSE s.requiere_humano END AS requiere_humano,
         s.notas_internas
    FROM cerebro_servicios s
   WHERE s.activo
     AND (NULLIF(p_busqueda,'') IS NULL
          OR s.clave = lower(trim(p_busqueda))
          OR s.nombre ILIKE '%'||trim(p_busqueda)||'%')
   ORDER BY s.nombre;
$function$
;

-- (207) The date an open recharge is booked for, when it was taken ahead of a confirmed promo (no promo running today):
-- the Cerebro reads it so it never promises that recharge for today or "en cuanto abramos". NULL otherwise.
CREATE OR REPLACE FUNCTION public.cerebro_recarga_anotada_para(p_conv uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT to_char(p.vigente_desde, 'DD/MM')
    FROM cerebro_promo_proxima() p
   WHERE NOT EXISTS (SELECT 1 FROM cerebro_promo_vigente())
     AND EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'recarga'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$;
REVOKE ALL ON FUNCTION public.cerebro_recarga_anotada_para(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_recarga_anotada_para(uuid) TO service_role;
