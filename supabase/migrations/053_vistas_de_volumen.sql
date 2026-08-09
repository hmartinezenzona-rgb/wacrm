-- =====================================================================
-- 053 — Vistas de volumen e historial (la mitad del "cuaderno de Osmany")
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Son SOLO VISTAS: no crean datos, no cambian nada, no las lee nadie
-- todavia. Revertirlas es un DROP VIEW.
--
-- QUE RESUELVEN Y QUE NO
--
--   ✅ VOLUMEN: cuanto se movio hoy, ayer, esta semana, este mes.
--   ✅ HISTORIAL: una fila por operacion, como una hoja de calculo.
--   ❌ GANANCIA: **no se puede calcular con lo que hay en la base.**
--
--   La tabla `tasas` tiene UNA sola columna de precio (`tasa_cup`), y es
--   **lo que se le cobra al cliente**: 2.8 CUP por GYD. Lo que NO existe
--   en ningun sitio es **cuanto le cuesta al negocio poner ese CUP en
--   Cuba**. Sin ese dato la ganancia no la calcula nadie.
--
--   Lo mismo con los demas servicios: se sabe que la traduccion se cobra
--   a 5.000 GYD/hoja, pero no lo que se le paga al traductor; que la
--   recarga se cobra a 6.200 GYD, pero no lo que cuesta comprarla.
--
--   **Esa es, casi seguro, la informacion que Osmany lleva a mano.** Su
--   hoja no duplica el CRM: tiene el dato que al CRM le falta.
--
-- COMO SE AÑADIRA LA GANANCIA CUANDO EXISTA EL DATO
--
--   Hara falta un coste por operacion. Lo mas simple que funciona es una
--   tabla paralela a `tasas` con el precio de COMPRA, y restar. **No se
--   crea ahora a proposito**: sin saber como lo lleva Osmany (tasa fija
--   negociada, variable por dia, con comisiones aparte...) cualquier
--   estructura que invente estaria mal y habria que rehacerla.
--
--   Cuando el dato exista, se añade una columna a estas vistas. La forma
--   de las vistas no cambia.
--
-- ROLLBACK
--   DROP VIEW IF EXISTS cerebro_historial_operaciones;
--   DROP VIEW IF EXISTS cerebro_resumen_volumen;
--   DROP FUNCTION IF EXISTS cerebro_volumen(date, date);
--   DROP VIEW IF EXISTS cerebro_volumen_diario;
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Volumen por dia y servicio — la base de todo lo demas
-- ---------------------------------------------------------------------
-- **El dia es el dia EN GUYANA, no en UTC.** Sin esto, a partir de las
-- 20:00 hora local el resumen empezaria a contar el dia siguiente y
-- "lo de hoy" no cuadraria con lo que ve el equipo.

CREATE OR REPLACE VIEW cerebro_volumen_diario AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  count(*)                                                 AS operaciones,
  sum(coalesce(d.value, o.quoted_source_amount, 0))        AS volumen_gyd,
  round(avg(coalesce(d.value, o.quoted_source_amount, 0))) AS ticket_medio_gyd
FROM remittance_operations o
LEFT JOIN deals d ON d.id = o.deal_id
WHERE o.status = 'completed'
GROUP BY 1, 2;


-- ---------------------------------------------------------------------
-- 2. Volumen entre dos fechas — para informes a medida
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_volumen(p_desde date, p_hasta date)
RETURNS TABLE (service_type text, operaciones bigint, volumen_gyd numeric, ticket_medio_gyd numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT v.service_type, sum(v.operaciones)::bigint, sum(v.volumen_gyd),
         CASE WHEN sum(v.operaciones) > 0
              THEN round(sum(v.volumen_gyd) / sum(v.operaciones)) END
    FROM cerebro_volumen_diario v
   WHERE v.dia BETWEEN p_desde AND p_hasta
   GROUP BY v.service_type;
$$;


-- ---------------------------------------------------------------------
-- 3. El resumen del dashboard: hoy / ayer / semana / mes / mes pasado
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW cerebro_resumen_volumen AS
WITH hoy AS (SELECT (now() AT TIME ZONE 'America/Guyana')::date AS d)
SELECT p.orden, p.periodo, p.desde, p.hasta,
       coalesce(sum(v.operaciones), 0)::bigint AS operaciones,
       coalesce(sum(v.volumen_gyd), 0)         AS volumen_gyd,
       CASE WHEN coalesce(sum(v.operaciones),0) > 0
            THEN round(sum(v.volumen_gyd) / sum(v.operaciones)) END AS ticket_medio_gyd
  FROM (
    SELECT 1 AS orden, 'hoy' AS periodo, d AS desde, d AS hasta FROM hoy
    UNION ALL SELECT 2, 'ayer',        d - 1,                        d - 1 FROM hoy
    UNION ALL SELECT 3, 'esta semana', date_trunc('week',  d)::date, d     FROM hoy
    UNION ALL SELECT 4, 'este mes',    date_trunc('month', d)::date, d     FROM hoy
    UNION ALL SELECT 5, 'mes pasado',
                     (date_trunc('month', d) - interval '1 month')::date,
                     (date_trunc('month', d) - interval '1 day')::date FROM hoy
  ) p
  LEFT JOIN cerebro_volumen_diario v ON v.dia BETWEEN p.desde AND p.hasta
 GROUP BY p.orden, p.periodo, p.desde, p.hasta;


-- ---------------------------------------------------------------------
-- 4. El historial: una fila por operacion, como una hoja de calculo
-- ---------------------------------------------------------------------
-- Las tarjetas se van a limpiar del Kanban, pero **los datos no se
-- borran ni se mueven a ningun sitio**: siguen aqui. Esta vista es la
-- que sustituye a mirar el tablero para consultar el pasado.
--
-- La tarjeta va enmascarada (4 primeros + 4 ultimos). Si algun dia se
-- necesita completa para un informe, se saca de `remittance_beneficiaries`.

CREATE OR REPLACE VIEW cerebro_historial_operaciones AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  o.status,
  ct.name   AS cliente,
  ct.phone  AS telefono,
  coalesce(d.value, o.quoted_source_amount, 0) AS monto_gyd,
  o.destination_currency,
  b.beneficiary_type,
  b.name    AS beneficiario,
  CASE WHEN b.card_number IS NOT NULL
       THEN left(b.card_number,4) || '****' || right(b.card_number,4) END AS tarjeta,
  b.phone   AS celular_beneficiario,
  b.zelle_account,
  o.deal_id,
  o.id      AS operation_id,
  o.created_at,
  o.completed_at
FROM remittance_operations o
LEFT JOIN deals d          ON d.id = o.deal_id
LEFT JOIN conversations cv ON cv.id = o.conversation_id
LEFT JOIN contacts ct      ON ct.id = coalesce(o.contact_id, cv.contact_id)
LEFT JOIN remittance_beneficiaries b
       ON b.operation_id = o.id AND b.status = 'vigente';


-- =====================================================================
-- ESTADO AL CREARLAS (9-ago-2026)
--
--   hoy .......... 0 operaciones          (domingo, negocio cerrado)
--   ayer ......... 9 ....... 225.000 GYD
--   esta semana .. 17 ...... 440.600 GYD   ticket medio 25.918
--   mes pasado ... 0                       **el CRM se abrio el 3-ago**
--
--   Ese ultimo cero no es un fallo: el sistema no puede contar lo que no
--   vio. Todo lo anterior al 3 de agosto vive solo en la hoja de Osmany.
--   Antes de comparar meses hay que decidir si se importa o si el CRM
--   arranca en agosto y la hoja queda como archivo historico.
--
-- LO QUE FALTA POR PREGUNTAR A OSMANY
--   1. Cuanto le cuesta poner 1 CUP en Cuba: ¿tasa fija negociada o
--      cambia cada dia como la de venta?
--   2. Lo mismo para recargas (coste de una recarga de 600 CUP) y
--      traduccion (lo que paga al traductor).
--   3. ¿Quiere repartir gastos fijos (comisiones MMG, transporte de
--      combos) o solo la diferencia entre lo que cobra y lo que paga?
-- =====================================================================
