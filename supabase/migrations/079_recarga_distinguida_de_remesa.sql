-- 079_recarga_distinguida_de_remesa.sql
-- YA APLICADA EN PRODUCCION (13-ago-2026). No la ejecutes de nuevo.
--
-- EL CASO: hoy 13-ago la recarga de la promo de Etecsa (Yilian, +5926595697,
-- 6.200 GYD) entro como "Remesa +5926595697" y el bot le pidio LA TARJETA.
-- El hueco estaba documentado al final de 19-que-se-le-pide-al-cliente.md:
-- service_type existe desde la 046 y no lo rellenaba nadie.
--
-- QUE HACE: cerebro_registrar_deposito detecta si la conversacion en curso es
-- una RECARGA y, en la rama (c) de envio nuevo:
--   * titula el deal 'Recarga +<telefono>' en vez de 'Remesa +<telefono>'
--   * marca remittance_operations.service_type = 'recarga' (el trigger
--     trg_sync_operacion_desde_deal crea la operacion en el mismo INSERT,
--     asi que el UPDATE posterior ya la ve)
-- Las ramas (a) idempotente, (b) movido y (b2) sumado NO cambian.
--
-- LA DETECCION, deliberadamente conservadora:
--   * el cliente escribio recarga/etecsa/cubacel (ILIKE, sin regex) DESPUES de
--     su ultimo envio cerrado, con tope de 24 horas hacia atras;
--   * y NO hay ninguna tarjeta en cerebro_beneficiario_parcial para la
--     conversacion: una tarjeta = remesa, aunque haya hablado de recargas.
-- La misma deteccion, con el mismo texto, vive en el nodo `Contexto
-- conversacion` del Cerebro (campo recarga_en_curso) para que el Decisor
-- no pida tarjeta. Si se cambia una, cambiar la otra.
--
-- COMO SE PROBO: DO-bloque con RAISE EXCEPTION (todo revertido) sobre la
-- conversacion real de Yilian: titulo 'Recarga +5926595697' y service_type
-- 'recarga'; y sobre una conversacion de remesa: titulo 'Remesa +...'.
--
-- REVERSION: volver a crear la funcion con el cuerpo de la 073 (el CASE del
-- titulo sin la rama v_recarga y sin el UPDATE de service_type).

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(
  p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rev     boolean;
  v_recarga boolean := false;
  v_ya      uuid;
  v_ex      uuid;
  v_suma    uuid;
  v_id      uuid;
  v_phone   text;
  v_ref     text;
  v_nota    text;
BEGIN
  v_rev := cerebro_es_revendedor(p_conv);

  -- La nota SIEMPRE lleva el comp_id, lo pusiera o no quien llama.
  v_nota := COALESCE(p_nota,'');
  IF NULLIF(p_comp_id,'') IS NOT NULL AND v_nota NOT LIKE '%'||p_comp_id||'%' THEN
    v_nota := v_nota || chr(10) || p_comp_id;
  END IF;

  -- (a) Idempotencia.
  IF NULLIF(p_comp_id,'') IS NOT NULL THEN
    SELECT d.id INTO v_ya FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND COALESCE(d.notes,'') LIKE '%'||p_comp_id||'%'
     LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (idempotente)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (b) Envio abierto SIN deposito al que engancharlo.
  IF NOT v_rev THEN
    SELECT d.id INTO v_ex
      FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.stage_id IN ('96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109',
                          '3cf01654-cd27-47c1-ac92-62abf5435751',
                          'f5cf87f8-b570-4d71-b6ea-a3cafd458c63')
       AND COALESCE(d.notes,'') NOT LIKE '%DEPOSITO%'
       AND NOT (d.value > 0 AND COALESCE(d.notes,'') LIKE '%BENEFICIARIO%')
     ORDER BY d.created_at DESC LIMIT 1;
  END IF;

  -- (b2) (073): envio abierto CON deposito pero INCOMPLETO.
  -- El cliente esta completando su envio en varios pagos.
  -- SOLO en "Por verificar": un envio en "Lista para transferir" ya esta
  -- cubierto y a punto de pagarse, y meterle dinero ahi seria otra cosa.
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT d.id INTO v_suma
      FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.stage_id = '3cf01654-cd27-47c1-ac92-62abf5435751'
       AND (SELECT s.saldo FROM cerebro_saldo_envio(d.id) s) > 0
     ORDER BY d.created_at DESC LIMIT 1;
  END IF;

  IF v_ex IS NOT NULL THEN
    UPDATE deals
       SET stage_id = p_stage, value = p_monto, currency = p_moneda,
           notes = COALESCE(notes,'') || E'\n---\n' || v_nota, updated_at = now()
     WHERE id = v_ex;
    PERFORM cerebro_objetivo_atar(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  IF v_suma IS NOT NULL THEN
    -- value se SUMA, no se reemplaza: el deal vale lo depositado en total.
    UPDATE deals
       SET stage_id = p_stage,
           value    = COALESCE(value, 0) + p_monto,
           currency = p_moneda,
           notes    = COALESCE(notes,'') || E'\n---\n' || v_nota,
           updated_at = now()
     WHERE id = v_suma;
    PERFORM cerebro_objetivo_atar(p_conv, v_suma);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (c) Envio nuevo.
  -- (079) ¿La conversacion en curso es una RECARGA? Ver cabecera.
  IF NOT v_rev THEN
    SELECT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.conversation_id = p_conv
                AND m.sender_type = 'customer'
                AND m.created_at > GREATEST(
                      now() - interval '24 hours',
                      COALESCE((SELECT max(d9.updated_at) FROM deals d9
                                 WHERE d9.conversation_id = p_conv
                                   AND (d9.status <> 'open'
                                        OR d9.stage_id = '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b')),
                               now() - interval '24 hours'))
                AND (m.content_text ILIKE '%recarga%'
                     OR m.content_text ILIKE '%etecsa%'
                     OR m.content_text ILIKE '%cubacel%'))
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_beneficiario_parcial bp
              WHERE bp.conversation_id = p_conv
                AND COALESCE(bp.tarjeta,'') <> '')
      INTO v_recarga;
  END IF;

  SELECT c.phone INTO v_phone
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv;
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');

  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id,
         '78220927-0745-45a8-ba08-a1b33734dbf1', p_stage,
         CASE WHEN v_rev
              THEN 'Remesa REVENDEDOR - Ref ' || COALESCE(v_ref, to_char(now(),'DDMM-HH24MI'))
              WHEN v_recarga
              THEN 'Recarga +' || COALESCE(v_phone,'?')
              ELSE 'Remesa +' || COALESCE(v_phone,'?') END,
         p_monto, p_moneda, v_nota, 'open'
    FROM conversations v WHERE v.id = p_conv
  RETURNING id INTO v_id;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar(p_conv, v_id); END IF;

  -- (079) La operacion de la escritura dual nace como 'remesa'; si esto es una
  -- recarga, se corrige aqui mismo, dentro de la misma transaccion.
  IF v_recarga THEN
    UPDATE remittance_operations ro
       SET service_type = 'recarga'
     WHERE ro.deal_id = v_id;
  END IF;

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;
