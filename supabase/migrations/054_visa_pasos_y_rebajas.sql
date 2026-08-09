-- =====================================================================
-- 054 — Visa: los pasos posteriores, y la regla de rebajas en todos
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- POR QUE LA VISA Y NO OTRA COSA
--
--   Osmany, preguntado por que servicio le quita mas tiempo respondiendo
--   lo mismo una y otra vez:
--
--     "Las extensiones de visa es el #1. Los otros tambien, pero son
--      menos frecuentes que las extensiones."
--
--   Y era el mas facil de todos: el texto que manda ya estaba escrito,
--   el precio es fijo, no necesita pipeline ni nada de la Fase 2, y el
--   bot ya tenia permiso para cerrarlo sin persona (`requiere_humano`
--   ya estaba en false).
--
--   Lo unico que le faltaba eran **los dos enlaces de Google Maps** que
--   Osmany manda a mano en cada caso.
--
-- ROLLBACK: quitar los dos enlaces y la frase de rebajas de `hechos`.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Los enlaces de los sitios a los que tiene que ir el cliente
-- ---------------------------------------------------------------------

UPDATE cerebro_servicios SET
  hechos = replace(hechos,
    '(1) ir a inmigracion con el PDF impreso y pagar alli 5,125 GYD;',
    '(1) ir a inmigracion con el PDF impreso y pagar alli 5,125 GYD o lo que corresponda segun su tramite. Inmigracion queda aqui: https://g.co/kgs/5cm8mdK ;'),
  actualizado = now()
 WHERE clave='visa';

UPDATE cerebro_servicios SET
  hechos = replace(hechos,
    'ir a la oficina de pasaporte antes de las 9am y recoger antes de las 4pm; ese paso no cuesta nada.',
    'ir a la oficina de pasaporte antes de las 9am y recoger antes de las 4pm; ese paso no cuesta nada. La oficina de pasaporte queda aqui: https://g.co/kgs/D1psrd1'),
  actualizado = now()
 WHERE clave='visa';


-- ---------------------------------------------------------------------
-- 2. Las rebajas las atiende SIEMPRE una persona — en TODOS los servicios
-- ---------------------------------------------------------------------
--   "Siempre las rebajas de precio las debo atender yo. El bot debe dar
--    una respuesta de la tarifa fija y decir que en caso de negociar una
--    rebaja siempre es conmigo."  (Osmany, 8-ago)
--
--   Estaba solo en `traduccion`. Aplica a los cinco.

UPDATE cerebro_servicios SET
  hechos = hechos || ' PROHIBIDO ofrecer rebajas, descuentos o precios especiales. Si el cliente pide rebaja, di la tarifa fija y que cualquier rebaja la trata una persona del equipo.',
  actualizado = now()
 WHERE clave IN ('combos','recargas','visa','mexico')
   AND hechos NOT LIKE '%PROHIBIDO ofrecer rebajas%';


-- =====================================================================
-- COMO SE PROBO (9-ago-2026), con el agente real
--
--   1. "Ya pague la extension de visa y me llego el PDF, que tengo que
--       hacer ahora?"
--
--      Respondio los CUATRO pasos con los dos enlaces de Maps y el
--      matiz de "o lo que corresponda segun su tramite". Es literalmente
--      el mensaje que Osmany escribe a mano cada vez.
--
--   2. "Y no me puedes hacer un descuento en la visa? soy cliente de
--       siempre"
--
--      "la tarifa de la visa es fija en 4,000 GYD y no manejamos
--       descuentos. Cualquier negociacion la ve una persona del equipo."
--
--      No invento un descuento ni se comprometio a nada.
--
-- NO SE TOCO EL PROMPT NI EL WORKFLOW. Solo datos en `cerebro_servicios`.
--
-- PENDIENTE DE OSMANY: la visa sube a 5.000 GYD "pronto", SIN FECHA.
-- No adelantarlo. Cuando lo diga:
--   UPDATE cerebro_servicios
--      SET hechos = replace(hechos, 'Cuesta 4,000 GYD', 'Cuesta 5,000 GYD')
--    WHERE clave='visa';
-- =====================================================================
