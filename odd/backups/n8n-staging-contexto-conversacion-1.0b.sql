WITH liberar_ambiguo AS (
  -- Solo recupera handoffs por operación ambigua ya resuelta. Los handoffs
  -- humanos, MLC y abuso no pasan por esta puerta.
  SELECT id FROM cerebro_liberar_derivacion_ambigua($1::uuid)
),
caducar_pausa AS (
  -- La pausa que deja un envio desde el panel (agent_replied) caduca tras
  -- N minutos sin actividad humana (102, decision del 15-sep). Libera de
  -- VERDAD para que la bandeja deje de mostrarlo pausado. La pausa manual
  -- y las derivaciones del bot NO pasan por aqui.
  SELECT id FROM cerebro_caducar_pausa_humana($1::uuid)
),
caducar AS (
  -- Una asignacion manual sin actividad humana durante N minutos se libera
  -- sola. Se libera de VERDAD (no se ignora) para que dispare
  -- trg_limpiar_memoria_al_liberar y el bot no anuncie una derivacion muerta.
  -- Las derivaciones del propio bot (perfil 377b0c8c...) NO caducan: si
  -- derivo fue por no saber seguir, y retomar solo seria peor.
  UPDATE conversations c
     SET assigned_agent_id = NULL
   WHERE c.id = $1::uuid
     AND c.assigned_agent_id IS NOT NULL
     AND c.assigned_agent_id <> '377b0c8c-c025-46ff-8088-7a929080831e'::uuid
     AND GREATEST(
           COALESCE(c.assigned_at, '-infinity'::timestamptz),
           COALESCE((SELECT max(m.created_at) FROM messages m
                      WHERE m.conversation_id = c.id
                        AND m.sender_type = 'agent'
                        AND COALESCE(m.ai_generated, false) = false),
                    '-infinity'::timestamptz)
         ) < now() - (COALESCE(cerebro_config_get('asignacion_caduca_minutos'), '10')::int * interval '1 minute')
  RETURNING c.id
),
derivar_mlc AS (
  -- MLC -> LO ATIENDE UNA PERSONA (084). La tasa del MLC varia mucho y la
  -- decision de Osmany es que el bot no la toque. Avisar no bastaba: sin
  -- derivar, el bot seguia llevando el chat y en el mensaje siguiente podia
  -- volver a cotizar.
  -- Se deriva al perfil de derivaciones del BOT, que NO caduca (ver `caducar`
  -- arriba): si se derivo fue por no saber seguir, y retomar solo seria peor.
  -- EL ORDEN IMPORTA, y juega a favor: como el SELECT de abajo lee la
  -- instantanea ANTERIOR, `asignado` sale todavia en false. Asi ESTE turno el
  -- bot aun habla —para decir que le atiende un companero— y a partir del
  -- siguiente mensaje ya se calla solo.
  -- No choca con `caducar`: aquella actua sobre asignaciones que EXISTEN y
  -- esta solo cuando NO hay ninguna.
  SELECT d.id
    FROM conversations c
    CROSS JOIN LATERAL cerebro_registrar_derivacion(
      c.id::uuid,
      'La vía MLC requiere confirmación de un operador.',
      'mlc',
      cerebro_pide_mlc(c.id)
    ) d
   WHERE c.id = $1::uuid
     AND c.assigned_agent_id IS NULL
)
-- OJO: el SELECT lee la instantanea ANTERIOR al UPDATE del CTE, asi que
-- v.assigned_agent_id todavia trae el valor viejo. De ahi el NOT EXISTS.
SELECT (v.deleted_at IS NOT NULL) AS oculta, (v.assigned_agent_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM caducar)
 AND NOT EXISTS (SELECT 1 FROM liberar_ambiguo)) AS asignado, EXISTS(SELECT 1 FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id WHERE ct.contact_id = v.contact_id AND lower(t.name) = 'admin') AS es_admin, EXISTS(SELECT 1 FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id WHERE ct.contact_id = v.contact_id AND lower(t.name) = 'recurrentes') AS es_recurrente, EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = v.id AND m.sender_type = 'agent' AND COALESCE(m.ai_generated,false) = false AND COALESCE(m.is_panel_action,false) = false AND m.created_at > now() - interval '5 minutes' AND m.created_at > COALESCE(v.ai_resumed_at, to_timestamp(0))) AS humano_reciente, cerebro_conversacion_no_vista(v.id) AS conversacion_no_vista,
-- ESTADO DEL COMPROBANTE QUE LLEGA REPETIDO ($2 = comp_id, vacio si no hay).
-- Antes la rama de duplicados del Decisor no preguntaba NADA: le decia al
-- cliente "recibimos su deposito, lo estamos revisando" pasara lo que pasara,
-- incluso si ese envio ya estaba entregado o el deposito ya se habia usado en
-- otro envio. Se busca por comp_id en TODAS las conversaciones a proposito:
-- una imagen reenviada puede venir del chat de otra persona.
(SELECT CASE o2.status
          WHEN 'collecting_information' THEN 'Solicitada'
          WHEN 'deposit_verification'   THEN 'Por verificar'
          WHEN 'ready_to_transfer'      THEN 'Lista para transferir'
          WHEN 'transferring'           THEN 'Lista para transferir'
          WHEN 'completed'              THEN 'Entregada'
          WHEN 'incident'               THEN 'Incidencia'
        END
   FROM remittance_operation_receipts r2
   JOIN remittance_operations o2 ON o2.id = r2.operation_id
  WHERE NULLIF($2::text,'') IS NOT NULL
    AND r2.comp_id = $2::text
  ORDER BY o2.created_at DESC, r2.created_at DESC LIMIT 1) AS dup_etapa,
(SELECT o2.quoted_source_amount
   FROM remittance_operation_receipts r2
   JOIN remittance_operations o2 ON o2.id = r2.operation_id
  WHERE NULLIF($2::text,'') IS NOT NULL
    AND r2.comp_id = $2::text
  ORDER BY o2.created_at DESC, r2.created_at DESC LIMIT 1) AS dup_valor
,
-- ¿SABEMOS A QUIEN HAY QUE TRANSFERIRLE? Fuente acumulada de toda la
-- conversacion, no solo del lote actual: la tarjeta pudo llegar hace 3 mensajes
-- y el Zelle en otro turno. Sin esto el bot promete "en breve le hacemos la
-- transferencia" sin saber a quien (visto el 10-ago con fran garcia).
EXISTS (SELECT 1 FROM remittance_operations o
          JOIN remittance_beneficiaries b ON b.operation_id = o.id
         WHERE o.conversation_id = v.id
           AND o.status NOT IN ('completed','cancelled')
           AND b.status = 'vigente'
           -- COMPLETO, no basta con uno de los dos. Criterio de Humberto el
           -- 10-ago. Medido: de 9 beneficiarios de tarjeta cubana los 9 tenian
           -- tarjeta Y celular, y de 14 de Zelle los 14 tenian cuenta y nombre.
           AND ((b.beneficiary_type = 'zelle'
                 AND COALESCE(b.zelle_account,'') <> '' AND COALESCE(b.name,'') <> '')
             OR (b.beneficiary_type <> 'zelle'
                 AND COALESCE(b.card_number,'') <> '' AND COALESCE(b.phone,'') <> ''))
       ) AS tiene_beneficiario,

-- ¿YA HAY DEPOSITO EN EL ENVIO EN CURSO, Y POR QUE VIA?
-- La pregunta "¿desde la app o con un agente?" sirve para decirle al cliente A
-- QUE CUENTA pagar. En cuanto existe un deposito, sobra: ya pago, y ademas
-- sabemos por donde, porque esta en las notas (Via: Agente MMG).
-- Se ata al ENVIO EN CURSO, no a "algun deposito": un cliente puede abrir una
-- segunda remesa y ahi la pregunta vuelve a ser legitima.
-- SIN EXPRESIONES REGULARES A PROPOSITO: el 10-ago un salto de linea escapado
-- dentro de un regex se deformo al pasar por JSON al subir el workflow y tumbo
-- este nodo 27 minutos. split_part no lleva barras invertidas.
-- Y OJO: el nodo Postgres de n8n PARTE LA CONSULTA POR PUNTO Y COMA, asi que
-- uno dentro de una cadena (o de un comentario) la rompe. Por eso chr(59).
(SELECT NULLIF(r3.via, '')
   FROM remittance_operation_receipts r3
   JOIN remittance_operations o3 ON o3.id = r3.operation_id
  WHERE o3.conversation_id = v.id
    AND o3.status NOT IN ('completed','cancelled')
  ORDER BY o3.created_at DESC, r3.created_at DESC LIMIT 1) AS via_deposito_ya_usada
,
-- ¿LA CONVERSACION EN CURSO ES UNA RECARGA? (079, 13-ago-2026). El cliente
-- escribio recarga/etecsa/cubacel despues de su ultimo envio cerrado (tope
-- 24 h) y NO ha dado tarjeta (tarjeta = remesa, aunque hable de recargas).
-- La misma deteccion vive en cerebro_registrar_deposito (079): cambiar una
-- es cambiar la otra. Sin punto y coma ni barras invertidas a proposito
-- (ver la nota de via_deposito_ya_usada).
(EXISTS (SELECT 1 FROM messages m9
          WHERE m9.conversation_id = v.id
            AND m9.sender_type = 'customer'
            AND m9.created_at > GREATEST(
                  now() - interval '24 hours',
                  COALESCE((SELECT max(CASE o9.status
                                WHEN 'completed' THEN o9.completed_at
                                WHEN 'cancelled' THEN o9.cancelled_at
                              END)
                    FROM remittance_operations o9
                   WHERE o9.conversation_id = v.id
                     AND o9.status IN ('completed','cancelled')),
                 now() - interval '24 hours'))
            AND (m9.content_text ILIKE '%recarga%'
                 OR m9.content_text ILIKE '%etecsa%'
                 OR m9.content_text ILIKE '%cubacel%'))
 AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                  WHERE bp.conversation_id = v.id
                    AND COALESCE(bp.tarjeta,'') <> '')) AS recarga_en_curso
,
-- MINUTOS ANTES DEL CIERRE en que el bot avisa de que la transferencia queda
-- para el dia siguiente. Vive en cerebro_config para moverlo sin desplegar
-- (0 lo apaga). Lo sirve esta consulta porque el Decisor es un nodo Code y no
-- puede consultar la base. Medido el 14-ago-2026: hasta las 13:00 el 97% de
-- los envios sale el mismo dia, desde las 15:00 baja al 60% y desde las 18:00
-- es 0%.
(  COALESCE(NULLIF(cerebro_config_get('cierre_aviso_minutos'), '')::int, 0) > 0
   AND extract(dow FROM (now() AT TIME ZONE 'America/Guyana')) <> 0
   AND (now() AT TIME ZONE 'America/Guyana')::time >= ((SELECT cierra FROM cerebro_horario())
         - make_interval(mins => COALESCE(NULLIF(cerebro_config_get('cierre_aviso_minutos'), '')::int, 0)))
   AND (now() AT TIME ZONE 'America/Guyana')::time <  (SELECT cierra FROM cerebro_horario())
) AS por_cerrar
,
-- HORARIO DEL NEGOCIO (136): una sola fuente, cerebro_config via cerebro_horario().
-- El Decisor y el agente leen de aqui la apertura y el cierre (minutos del dia y texto).
(SELECT (EXTRACT(hour FROM abre) * 60 + EXTRACT(minute FROM abre))::int FROM cerebro_horario()) AS horario_abre_min
,
(SELECT (EXTRACT(hour FROM cierra) * 60 + EXTRACT(minute FROM cierra))::int FROM cerebro_horario()) AS horario_cierra_min
,
(SELECT to_char(date '2000-01-01' + abre, 'FMHH12:MIam') FROM cerebro_horario()) AS horario_abre_texto
,
(SELECT to_char(date '2000-01-01' + cierra, 'FMHH12:MIam') FROM cerebro_horario()) AS horario_cierra_texto
,
-- BOT PAUSADO A MANO en esta conversacion. La columna la escribe WaCRM desde
-- el boton de "tomar el control" del hilo (AiThreadBanner -> POST
-- /api/ai/autoreply/[id]), y hasta hoy el Cerebro NO la miraba: se callaba
-- solo por el efecto colateral de que ese boton tambien ASIGNA el chat.
-- Eso no bastaba, porque las asignaciones manuales CADUCAN solas (ver el CTE
-- `caducar` de arriba): pasados los minutos sin actividad humana el chat se
-- liberaba y el bot volvia a hablar con la pausa todavia puesta.
(COALESCE(v.ai_autoreply_disabled, false)
 AND NOT EXISTS (SELECT 1 FROM liberar_ambiguo)
 AND NOT EXISTS (SELECT 1 FROM caducar_pausa)) AS bot_pausado
,
-- EL CLIENTE PREGUNTA POR MLC (084). El MLC no es un servicio del sistema y no
-- tiene tasa: preguntado por el, el bot caia en la del DOLAR y cotizaba mal
-- (12-ago y 13-ago, a Yoandy cruz, las dos a 260 GYD por unidad). La deteccion
-- vive en `cerebro_pide_mlc` para que sea la MISMA que usa el aviso al admin
-- desde `Control de abuso`.
cerebro_pide_mlc(v.id) AS pide_mlc
,
-- ¿LA RAFAGA ES CORTESIA PURA? (086). Idea de Osmany: que el bot CIERRE el
-- agradecimiento en vez de que el vigilante lo filtre. Si nadie deja el mensaje
-- sin responder, no hay chat atascado — en cualquier redaccion y cualquier
-- idioma. La regla es la MISMA que usa el vigilante (`cerebro_es_cortesia`),
-- para que no puedan discrepar.
-- Se miran TODOS los mensajes del cliente posteriores a la ultima respuesta,
-- no solo el ultimo: si mando "gracias" y luego "oye y lo mio?", la rafaga NO
-- es cortesia. `bool_and` sobre conjunto vacio da NULL, que en el Decisor cae a
-- false.
(SELECT bool_and(cerebro_es_cortesia(m.content_text, m.content_type))
   FROM messages m
  WHERE m.conversation_id = v.id
    AND m.sender_type = 'customer'
    AND m.created_at > COALESCE((SELECT max(a.created_at) FROM messages a
                                  WHERE a.conversation_id = v.id
                                    AND a.sender_type = 'agent'),
                                '-infinity'::timestamptz)) AS cierra_cortesia
,
-- SUELO DEL TRANSID (087). El contador de MMG solo crece: por debajo de este
-- numero la referencia no puede existir. Se sirve para que el Decisor pueda
-- callar la confirmacion al cliente cuando la vision se inventa la referencia.
-- El valor vive en cerebro_config; aqui solo se transporta, la regla es de
-- `cerebro_transid_plausible` y de la 087.
COALESCE(NULLIF(cerebro_config_get('transid_minimo'), '')::numeric, 10378363543358) AS transid_minimo
,
-- MUESTRA DE IDIOMA (14-ago-2026). El Decisor es un nodo Code y solo ve el
-- lote actual, asi que el idioma se re-deducia en cada turno. Con un lote
-- flojo -- "Mmm interesting / 53821203 / There" -- no habia casi señal
-- inglesa, y el contexto, que va ENTERO en español, arrastro la respuesta al
-- español a mitad de una conversacion en ingles. El cliente tuvo que decir
-- "I don't understand you" para recuperarlo.
-- Esto le lleva lo que el cliente ESCRIBIO antes, para que el idioma sea una
-- propiedad de la CONVERSACION y no del ultimo lote. Aqui solo se transporta:
-- quien decide es el Decisor, que si tiene banco.
-- Solo texto del cliente y solo mensajes con letras suficientes para
-- significar algo: un "53821203" o un "Ok" no dicen en que idioma habla.
(SELECT string_agg(t.content_text, ' ' ORDER BY t.created_at DESC)
   FROM (SELECT m.content_text, m.created_at
           FROM messages m
          WHERE m.conversation_id = v.id
            AND m.sender_type = 'customer'
            AND m.content_type = 'text'
            AND length(regexp_replace(COALESCE(m.content_text, ''), '[^[:alpha:]]', '', 'g')) >= 8
          ORDER BY m.created_at DESC
          LIMIT 6) t) AS muestra_idioma
,
-- CANDIDATO: MUESTRA DE IDIOMA POR MENSAJE (doc 61 §6/§7).
-- NO sustituye a `muestra_idioma`: se anade AL LADO, para poder medir sin
-- cambiar nada. El campo viejo se queda hasta que haya una regla que lo use.
--
-- Que arregla respecto al string pegado de hoy:
--   - conserva la FRONTERA entre mensajes, que es lo unico que permite
--     distinguir "el cliente escribe en ingles" de "el cliente pego un ingles",
--   - marca cual pertenece al LOTE actual (`es_actual`), con la misma
--     definicion que ya usa `cierra_cortesia`: posterior a la ultima respuesta
--     del agente. Asi el Decisor deja de tener que adivinarlo por prefijo,
--   - conserva el timestamp, que abre la puerta a una ventana reciente,
--   - excluye los marcadores del SISTEMA, que hoy entran como si fueran del
--     cliente y aportan senal inglesa falsa.
--
-- SIN PUNTO Y COMA Y SIN BARRAS INVERTIDAS a proposito: el nodo Postgres de n8n
-- parte la consulta por punto y coma, y el 10-ago un salto de linea escapado
-- dentro de un regex se deformo al pasar por JSON y tumbo este nodo 27 minutos.
(SELECT json_agg(json_build_object(
          'texto', t.content_text,
          'created_at', t.created_at,
          'es_actual', t.es_actual) ORDER BY t.created_at DESC)
   FROM (SELECT m.content_text, m.created_at,
                (m.created_at > COALESCE((SELECT max(a.created_at) FROM messages a
                                           WHERE a.conversation_id = v.id
                                             AND a.sender_type = 'agent'),
                                         '-infinity'::timestamptz)) AS es_actual
           FROM messages m
          WHERE m.conversation_id = v.id
            AND m.sender_type = 'customer'
            AND m.content_type = 'text'
            AND m.content_text NOT LIKE '[Unsupported message type:%'
            AND length(regexp_replace(COALESCE(m.content_text, ''), '[^[:alpha:]]', '', 'g')) >= 8
          ORDER BY m.created_at DESC
          LIMIT 6) t) AS muestra_idioma_mensajes
,
-- CATALOGO DE SERVICIOS (138): una sola fuente, cerebro_servicios via
-- cerebro_catalogo_servicios(). El agente lee de aqui la lista de
-- servicios ademas de remesas (ver OTROS SERVICIOS del prompt), mismo
-- patron que horario_abre_texto/horario_cierra_texto arriba (136).
(SELECT cerebro_catalogo_servicios()) AS catalogo_servicios
,
-- EL DEPOSITO DE LA OPERACION ACTUAL, YA ESTABA VERIFICADO DESDE ANTES DE
-- ESTE TURNO? (B1.2, 2026-09-29). VERIFIED_STATUSES son las mismas que usa
-- src/components/inbox/operations/deposit-review-section.tsx: ready_to_
-- transfer, transferring y completed. Hasta hoy el Decisor solo sabia si
-- ESTE turno trae un comprobante recien cruzado por `Cruzar deposito con
-- MMG`; un deposito verificado a mano desde el panel (force-verify, B4.3) o
-- en un turno anterior no dejaba ningun rastro aqui, y el bot seguia
-- prometiendo "apenas lo verifiquemos" sobre algo que ya paso.
-- MISMO patron o.conversation_id = v.id que tiene_beneficiario arriba; se
-- toma la operacion mas reciente NO cancelada, para no mirar una remesa
-- vieja y ya cerrada de otra conversacion.
-- Una remesa YA TERMINADA (completed) no cuenta: es una remesa anterior, no
-- el envio en curso. Con 'completed' dentro, 115 conversaciones de produccion
-- de clientes recurrentes quedaban marcadas (medido el 2026-09-30).
(SELECT o6.status IN ('ready_to_transfer', 'transferring')
   FROM remittance_operations o6
  WHERE o6.conversation_id = v.id
    AND o6.status NOT IN ('cancelled', 'completed')
  ORDER BY o6.created_at DESC
  LIMIT 1) AS deposito_ya_verificado
,
-- CUANTO RECIBE el destinatario, y en que moneda? (B1.1, 2026-09-29; 153).
-- NUNCA se calcula aqui: cerebro_monto_recibe (153) devuelve el monto de la
-- operacion en curso si ya lo tiene (tras el deposito), y si no, la ultima
-- cotizacion que el bot le dio al cliente en la moneda de la via elegida
-- (tarjeta cubana -> CUP; Zelle/Clasica/Tropical -> USD), si es de ESTE envio
-- y de menos de 24 h. Efectivo o via desconocida -> NULL: no se dice cifra.
(SELECT r.valor FROM cerebro_monto_recibe(v.id) r) AS monto_recibe_valor,
(SELECT r.moneda FROM cerebro_monto_recibe(v.id) r) AS monto_recibe_moneda
,
-- ¿HAY UNA ENTREGA EN EFECTIVO (efectivo_usd) EN CURSO, Y QUE FALTA? (B1.4,
-- 2026-09-29). `crm_registrar_datos_entrega_efectivo` (150) guarda telefono,
-- direccion y foto del carnet POR OPERACION: una vez dado un dato en ESTE
-- envio no se vuelve a pedir, pero un envio efectivo_usd NUEVO si pregunta de
-- nuevo. El agente necesita saber que sigue en null para no repreguntar lo ya
-- dado. MISMO filtro service_type/delivery_method/status que usa la propia
-- RPC (150) para encontrar 'la' operacion efectivo_usd en curso, asi esta
-- bandera nunca discrepa de lo que la RPC vera si se le llama. MISMO patron
-- o.conversation_id = v.id y beneficiary_type/vigente que tiene_beneficiario
-- arriba.
EXISTS (SELECT 1 FROM remittance_operations o8
         WHERE o8.conversation_id = v.id
           AND o8.service_type = 'remesa'
           AND o8.delivery_method = 'efectivo_usd'
           AND o8.status NOT IN ('completed', 'cancelled')) AS entrega_efectivo_en_curso,
COALESCE((SELECT array_remove(ARRAY[
            CASE WHEN b8.phone IS NULL THEN 'telefono' END,
            CASE WHEN b8.address IS NULL THEN 'direccion' END,
            CASE WHEN b8.id_photo_wamid IS NULL THEN 'carnet' END
          ], NULL)
   FROM remittance_operations o8
   LEFT JOIN remittance_beneficiaries b8
     ON b8.operation_id = o8.id AND b8.beneficiary_type = 'efectivo_usd' AND b8.status = 'vigente'
  WHERE o8.conversation_id = v.id
    AND o8.service_type = 'remesa'
    AND o8.delivery_method = 'efectivo_usd'
    AND o8.status NOT IN ('completed', 'cancelled')
  ORDER BY o8.created_at DESC
  LIMIT 1), ARRAY['telefono','direccion','carnet']) AS entrega_efectivo_falta

FROM conversations v WHERE v.id = $1::uuid;

