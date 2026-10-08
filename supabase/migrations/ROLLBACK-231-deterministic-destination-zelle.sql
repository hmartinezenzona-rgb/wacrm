-- ROLLBACK of 231_deterministic_destination_zelle.sql: restores the pre-231 definitions exactly as staging had them on 2026-10-08
-- (pg_get_functiondef md5): cerebro_detectar_destino 31f6d02d599b491c586284251b0502f9, cerebro_registrar_destino c87c36beafde0cd256a601ee7290d045,
-- cerebro_marcar_destino_usd f239d898e9533b82a9822f4eb98ee6e7 (= 174 / 157 / 221). Drops the v2 function, the two helpers, the operation-created
-- trigger and its function, deletes the pending 'zelle' rows (the restored check refuses them), drops the origen column and restores the
-- tipo check (clasica, tropical, cuban_card). Operations already switched to Zelle by the bot keep their data and audit rows.
-- Run it only after the n8n node no longer calls cerebro_registrar_destino_v2.

DROP TRIGGER IF EXISTS trg_zz_destino_zelle_al_crear ON public.remittance_operations;
DROP FUNCTION IF EXISTS public.cerebro_destino_pendiente_op_creada();

CREATE OR REPLACE FUNCTION public.cerebro_marcar_destino_usd(p_conversation_id uuid, p_tipo text, p_execution_id text)
 RETURNS TABLE(id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Procedural, not a single CTE chain, for one concrete reason: the
-- `ins` branch must set delivery_method on the operation it has JUST
-- created, and every statement in one WITH chain shares one snapshot, so
-- an UPDATE cannot see the row inserted by cerebro_crear_operacion() in
-- the same statement. Two statements are needed, so the branches are
-- sequenced explicitly. The branch order and the emitted rows are exactly
-- the node's union order: falta, upd, ins, sin_cambio, ambiguo — with the
-- one multi-row case the node has (an invalid tipo AND two open
-- operations emits falta + ambiguo) preserved.
DECLARE
  v_resultado text;
  v_op        uuid;
  v_k         text;
  v_reg       integer;
  v_t         text;
  v_marker    text;
  v_actual    text;
  v_ben       text;
  v_nuevo     uuid;
BEGIN
  -- Inlined cerebro_resolver_operacion(uuid, text[]): see the header.
  SELECT CASE WHEN count(*) = 0 THEN 'ninguna'
              WHEN count(*) = 1 THEN 'unica'
              ELSE 'ambigua' END,
         CASE WHEN count(*) = 1
              THEN (SELECT o.id FROM remittance_operations o
                     WHERE o.conversation_id = p_conversation_id
                       AND o.status NOT IN ('completed','cancelled')
                       AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
                     LIMIT 1)
         END
    INTO v_resultado, v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status NOT IN ('completed','cancelled')
     AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);

  v_k := p_execution_id || ':marcar_destino_usd:' || md5(coalesce(p_tipo,''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT v_k, 'marcar_destino_usd', p_execution_id, p_conversation_id, v_op,
         jsonb_build_array(to_jsonb(p_tipo::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING 1 INTO v_reg;

  v_t := CASE WHEN lower(p_tipo) LIKE 'trop%' THEN 'Tropical'
              WHEN lower(p_tipo) LIKE 'cl%'   THEN 'Clasica'
              WHEN lower(p_tipo) LIKE 'efec%' THEN 'Efectivo' END;
  -- 151 line 77: the notes marker the trigger turns into delivery_method is
  -- lower(t) for Clasica/Tropical and the literal 'efectivo_usd' for
  -- Efectivo. Same expression the old trigger's UPDATE used.
  v_marker := CASE WHEN v_t = 'Efectivo'      THEN 'efectivo_usd'
                   WHEN v_t IS NOT NULL       THEN lower(v_t) END;

  -- falta
  IF v_t IS NULL THEN
    RETURN QUERY SELECT NULL::uuid AS id,
      'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.'::text AS accion;
  END IF;

  -- abierto: upd / sin_cambio (both need an operation, and a rail)
  IF v_op IS NOT NULL THEN
    IF v_t IS NOT NULL THEN
      SELECT o.delivery_method,
             (SELECT b.beneficiary_type FROM remittance_beneficiaries b
               WHERE b.operation_id = o.id AND b.status = 'vigente'
               LIMIT 1)
        INTO v_actual, v_ben
        FROM remittance_operations o WHERE o.id = v_op;

      -- 'ENTREGA EN USD: <t>' in deals.notes becomes delivery_method = marker(t).
      IF coalesce(v_actual = v_marker, false) THEN
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        RETURN QUERY SELECT v_op AS id,
          'sin cambios: ese destino ya estaba marcado'::text AS accion;
      ELSE
        UPDATE remittance_operations o
           SET delivery_method = coalesce(v_marker, v_ben, o.delivery_method)
         WHERE o.id = v_op
           AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, v_ben, o.delivery_method);
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        RETURN QUERY SELECT v_op AS id,
          ('destino marcado: entrega en USD por ' || v_t)::text AS accion;
      END IF;
    END IF;
    RETURN;
  END IF;

  -- no operation: ambiguo, or the node's `ins`
  IF v_resultado = 'ambigua' THEN
    RETURN QUERY
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             true) d;
  ELSIF v_t IS NOT NULL THEN
    v_nuevo := cerebro_crear_operacion(p_conversation_id);
    UPDATE remittance_operations o
       SET delivery_method = coalesce(v_marker, o.delivery_method)
     WHERE o.id = v_nuevo
       AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, o.delivery_method);
    -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
    IF v_t IN ('Clasica', 'Tropical') THEN
      PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
    END IF;
    RETURN QUERY SELECT v_nuevo AS id,
      ('envio nuevo creado, entrega en USD por ' || v_t)::text AS accion;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_destino(p_conv uuid, p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tipo  text;
  v_n     integer := 0;
  v_op_id uuid;
  v_lock  jsonb;
BEGIN
  v_tipo := cerebro_detectar_destino(p_texto);
  IF v_tipo IS NULL THEN
    RETURN NULL;
  END IF;

  -- Last statement wins. A customer who corrects the rail corrects it.
  INSERT INTO public.cerebro_destino_pendiente (conversation_id, tipo, actualizado)
  VALUES (p_conv, v_tipo, now())
  ON CONFLICT (conversation_id) DO UPDATE
     SET tipo = EXCLUDED.tipo,
         actualizado = EXCLUDED.actualizado;

  SELECT count(*) OVER (), o.id, o.admin_locked_fields
    INTO v_n, v_op_id, v_lock
    FROM public.remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.service_type = 'remesa'
     AND o.status NOT IN ('completed', 'cancelled')
   LIMIT 1;

  IF v_n = 1 THEN
    v_lock := coalesce(v_lock, '{}'::jsonb);

    -- 'beneficiaries' is 098's lock (a human added or corrected a
    -- beneficiary), 'delivery_method' is 096's (a human set the rail).
    -- Either one means a person already decided this on purpose.
    IF NOT (v_lock ? 'beneficiaries') AND NOT (v_lock ? 'delivery_method') THEN
      -- Card-rail rows only. zelle, multiple_distribution and efectivo_usd
      -- are different kinds of delivery and are never re-typed by this.
      UPDATE public.remittance_beneficiaries
         SET beneficiary_type = v_tipo
       WHERE operation_id = v_op_id
         AND status = 'vigente'
         AND beneficiary_type IN ('cuban_card', 'clasica', 'tropical');

      UPDATE public.remittance_operations
         SET delivery_method = v_tipo
       WHERE id = v_op_id
         AND (delivery_method IS NULL
              OR delivery_method IN ('cuban_card', 'clasica', 'tropical'));

      -- The same call 100's recalc triggers make and 111's one-time
      -- recompute makes. Wrapped like 100's: a calculator failure must not
      -- throw away the destination the customer actually asked for. The
      -- re-type above has already re-fired the calculator through
      -- trg_zz_recalc_destino_beneficiaries; this call is what covers the
      -- case where the row was already the right type.
      BEGIN
        PERFORM crm_calcular_monto_destino(v_op_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[wacrm] crm_calcular_monto_destino failed after destino % on operation % (%): %',
          v_tipo, v_op_id, SQLSTATE, SQLERRM;
      END;
    END IF;
  END IF;

  RETURN v_tipo;
END $function$;

DROP FUNCTION IF EXISTS public.cerebro_registrar_destino_v2(uuid, text, text, boolean);

CREATE OR REPLACE FUNCTION public.cerebro_detectar_destino(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_txt      text := coalesce(p_texto, '');
  v_clasica  boolean;
  v_tropical boolean;
  v_cup      boolean;
BEGIN
  -- (174) Plurals too: "a unas tarjetas clasicas", "a las tropicales".
  v_clasica  := v_txt ~* '(^|[^[:alnum:]])cl[aáAÁ]sicas?([^[:alnum:]]|$)';
  v_tropical := v_txt ~* '(^|[^[:alnum:]])tropical(es)?([^[:alnum:]]|$)';
  v_cup      := v_txt ~* '(^|[^[:alnum:]])cup([^[:alnum:]]|$)'
             OR v_txt ~* '(^|[^[:alnum:]])pesos[[:space:]]+cubanos([^[:alnum:]]|$)';

  IF v_clasica AND NOT v_tropical THEN
    RETURN 'clasica';
  ELSIF v_tropical AND NOT v_clasica THEN
    RETURN 'tropical';
  ELSIF v_cup AND NOT v_clasica AND NOT v_tropical THEN
    RETURN 'cuban_card';
  END IF;

  -- Both rails named, or nothing this function recognises.
  RETURN NULL;
END $function$;

DROP FUNCTION IF EXISTS public.cerebro_destino_es_pregunta(text);
DROP FUNCTION IF EXISTS public.cerebro_destino_riel_negado(text, text);

DELETE FROM public.cerebro_destino_pendiente WHERE tipo = 'zelle';
ALTER TABLE public.cerebro_destino_pendiente DROP COLUMN IF EXISTS origen;
ALTER TABLE public.cerebro_destino_pendiente DROP CONSTRAINT cerebro_destino_pendiente_tipo_check;
ALTER TABLE public.cerebro_destino_pendiente ADD CONSTRAINT cerebro_destino_pendiente_tipo_check
  CHECK (tipo = ANY (ARRAY['clasica'::text, 'tropical'::text, 'cuban_card'::text]));

NOTIFY pgrst, 'reload schema';
