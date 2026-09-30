WITH cli AS (SELECT contact_id FROM conversations WHERE id = $1::uuid),
-- R1: la ventana de 20 operaciones del contacto, con la misma valla de
-- 1 minuto aplicada al created_at de la OPERACION (125:54 garantiza que
-- ro.created_at = el created_at del deal, asi que la valla sigue valiendo).
ops AS (
  SELECT ro.id AS operation_id,
         ro.quoted_source_amount AS value,
         ro.source_currency AS currency,
         ro.created_at,
         ro.status,
         ro.updated_at
  FROM remittance_operations ro
  WHERE ro.contact_id = (SELECT contact_id FROM cli)
    AND ro.created_at < now() - interval '1 minute'
),
-- R2: el recibo MAS NUEVO de la operacion -> banco_destino / destinatario_dep.
-- El brief manda ordenar por el created_at de la OPERACION primero: los
-- recibos 'backfill' de 156 tienen created_at = fecha de la migracion, asi
-- que created_at de la operacion es la unica reloj fiable del historico.
recibo AS (
  SELECT DISTINCT ON (rc.operation_id)
         rc.operation_id,
         rc.via,
         rc.recipient
  FROM remittance_operation_receipts rc
  JOIN ops o ON o.operation_id = rc.operation_id
  ORDER BY rc.operation_id, o.created_at DESC, rc.created_at DESC, rc.id DESC
),
-- R3: la etapa en espanol, mapa inverso exacto de cerebro_estado_desde_etapa
-- (041:36-46). Los nombres viven solo en pipeline_stages.name, asi que hay
-- que hardcodearlos igual que en 1.0b.
etapa_nombre AS (
  SELECT *
  FROM (VALUES
    ('collecting_information', 'Solicitada'),
    ('deposit_verification', 'Por verificar'),
    ('ready_to_transfer', 'Lista para transferir'),
    ('completed', 'Entregada'),
    ('incident', 'Incidencia')
  ) AS t(status, nombre)
),
-- R4: corregido. El flag CORREGIDO no tiene escritor en ninguna migracion;
-- su equivalente estructurado es doble: una correccion del panel sobre la
-- operacion (remittance_admin_audit action 'human_correction', 098) o un
-- beneficiario '--reemplazado--' (098:303,410,489 / 042:170).
deals_cli AS (
  SELECT o.operation_id,
         o.value,
         o.currency,
         o.created_at,
         -- notas: el texto de notas deja de leerse de deals. Se RECONSTRUYE
         -- con el mismo formato que producen los nodos n8n de beneficiario
         -- (Tarjeta: / Celular:, bloques separados por chr(10)||'---'||chr(10),
         -- que es el separador de bloque real de las notas), para que ningun
         -- consumidor futuro del blob reciba otra cosa. `pares` NO lo relee:
         -- lee las columnas de remittance_beneficiaries de abajo.
         (SELECT COALESCE(string_agg(
                  'Tarjeta: ' || b.card_number || chr(10) || 'Celular: ' || b.phone,
                  chr(10) || '---' || chr(10)
                  ORDER BY b.block_index DESC NULLS LAST, b.position), '')
            FROM remittance_beneficiaries b
           WHERE b.operation_id = o.operation_id
             AND b.status = 'vigente') AS notas,
         (EXISTS (SELECT 1
                    FROM remittance_admin_audit raa
                   WHERE raa.table_name = 'remittance_operations'
                     AND raa.row_id = o.operation_id
                     AND raa.action = 'human_correction')
          OR EXISTS (SELECT 1
                       FROM remittance_beneficiaries rb2
                      WHERE rb2.operation_id = o.operation_id
                        AND rb2.status = 'reemplazado')) AS corregido,
         rc.via AS banco_destino,
         rc.recipient AS destinatario_dep
  FROM ops o
  LEFT JOIN recibo rc ON rc.operation_id = o.operation_id
  ORDER BY o.created_at DESC
  LIMIT 20
)
, envios AS (SELECT * FROM deals_cli WHERE value > 0), cuentas AS (SELECT CASE WHEN lower(COALESCE(banco_destino,'')||' '||COALESCE(destinatario_dep,'')) ~ '(merchant|{{ JSON.parse($('Datos del negocio').params.jsonOutput).app.titular.toLowerCase().split(' ').pop() }}|{{ JSON.parse($('Datos del negocio').params.jsonOutput).app.pay_merchant }})' THEN 'App MMG, Pay Merchant {{ JSON.parse($('Datos del negocio').params.jsonOutput).app.pay_merchant }}' WHEN lower(COALESCE(banco_destino,'')||' '||COALESCE(destinatario_dep,'')) ~ '(agent|cashin|cash in|{{ JSON.parse($('Datos del negocio').params.jsonOutput).agente.cuenta }}|{{ JSON.parse($('Datos del negocio').params.jsonOutput).agente.titular.toLowerCase().split(' ').pop() }})' THEN 'Agente MMG {{ JSON.parse($('Datos del negocio').params.jsonOutput).agente.cuenta }}' WHEN lower(COALESCE(banco_destino,'')||' '||COALESCE(destinatario_dep,'')) ~ '({{ JSON.parse($('Datos del negocio').params.jsonOutput).mexico.banco.toLowerCase() }}|clabe|spei)' THEN '{{ JSON.parse($('Datos del negocio').params.jsonOutput).mexico.banco }}, CLABE {{ JSON.parse($('Datos del negocio').params.jsonOutput).mexico.clabe }}' WHEN lower(COALESCE(banco_destino,'')||' '||COALESCE(destinatario_dep,'')) ~ 'zelle' THEN 'Zelle hmartinez.enzona@gmail.com' ELSE NULL END AS cuenta FROM envios), habitual AS (SELECT cuenta, count(*)::int AS n FROM cuentas WHERE cuenta IS NOT NULL GROUP BY cuenta ORDER BY count(*) DESC LIMIT 1),
-- R5: pares tarjeta/celular, directo de remittance_beneficiaries (vigente).
-- Se lee la fila estructurada en vez de reconstruir el texto de notas y
-- reparsearlo: mismo dato, sin el roundtrip por regex.
pares AS (
  SELECT dc.created_at,
         b.card_number AS tarjeta,
         b.phone AS celular
  FROM deals_cli dc
  JOIN remittance_beneficiaries b ON b.operation_id = dc.operation_id
  WHERE NOT dc.corregido
    AND b.status = 'vigente'
    AND b.card_number IS NOT NULL
    AND b.phone IS NOT NULL
), benef AS (SELECT DISTINCT ON (tarjeta) tarjeta, celular, created_at AS ultimo_uso FROM pares ORDER BY tarjeta, created_at DESC),
abierto AS (
  SELECT en.nombre AS etapa,
         o.quoted_source_amount AS value,
         o.source_currency AS currency
  FROM remittance_operations o
  LEFT JOIN etapa_nombre en ON en.status = o.status
  WHERE o.contact_id = (SELECT contact_id FROM cli)
    AND o.status IN ('collecting_information', 'deposit_verification',
                     'ready_to_transfer', 'incident')
  ORDER BY o.created_at DESC
  LIMIT 1
) SELECT (SELECT count(*) FROM envios)::int AS envios_previos, (SELECT to_char(max(created_at), 'YYYY-MM-DD') FROM envios) AS ultimo_envio, (SELECT (value::text || ' ' || currency) FROM envios ORDER BY created_at DESC LIMIT 1) AS ultimo_monto, (SELECT cuenta FROM habitual WHERE n >= 2) AS cuenta_negocio_habitual, (SELECT n FROM habitual WHERE n >= 2) AS veces_cuenta_habitual, (SELECT json_agg(json_build_object('tarjeta', tarjeta, 'celular', celular, 'ultimo_uso', to_char(ultimo_uso, 'YYYY-MM-DD')) ORDER BY ultimo_uso DESC) FROM benef) AS beneficiarios, 
       (SELECT en.nombre
        FROM remittance_operations o
        LEFT JOIN etapa_nombre en ON en.status = o.status
        WHERE o.contact_id = (SELECT contact_id FROM cli)
          AND o.created_at < now() - interval '1 minute'
        ORDER BY o.updated_at DESC
        LIMIT 1) AS ultimo_estado,(SELECT etapa FROM abierto) AS etapa_envio_abierto, (SELECT (value::text || ' ' || currency) FROM abierto) AS monto_envio_abierto, (NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = $1::uuid AND m.sender_type = 'agent' AND (m.created_at AT TIME ZONE 'America/Guyana')::date = (now() AT TIME ZONE 'America/Guyana')::date AND COALESCE(m.content_text,'') NOT LIKE 'Su deposito de%ya fue verificado%' AND COALESCE(m.content_text,'') NOT LIKE 'Listo, su remesa fue completada%' AND COALESCE(m.content_text,'') NOT LIKE 'Un momento por favor%')) AS primer_del_dia,
  (SELECT count(*)::int
         FROM remittance_operations o
        WHERE o.contact_id = (SELECT contact_id FROM cli)
          AND o.status IN ('collecting_information', 'deposit_verification',
                           'ready_to_transfer', 'incident')) AS envios_abiertos;
