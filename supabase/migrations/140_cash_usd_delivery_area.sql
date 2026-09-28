-- =====================================================================
-- 140 — Cash USD delivery: provinces and municipalities go to a human
--
-- WHY
--   The other admin said on 2026-09-28 that the provinces and
--   municipalities for cash USD delivery must be discussed directly with
--   the team. The bot must never say whether a place is covered.
--
-- WHAT
--   Updates only hechos and notas_internas of the efectivo_usd row.
--   Facts from 137/139 are kept.
--
-- IDEMPOTENT: a plain UPDATE of one row.
-- ROLLBACK: ROLLBACK-140-cash-usd-delivery-area.sql (restores the 139 text)
-- =====================================================================

UPDATE cerebro_servicios SET
  hechos = 'Entrega de dolares en efectivo, fisicos, en Cuba. Tasa propia: 290 GYD por cada 1 USD (NO es la misma tasa de Zelle/Clasica/Tropical, que es 260). Minimo 100 USD por entrega, o sea minimo 29,000 GYD a depositar (100 x 290). El deposito se hace por MMG, igual que las demas vias. Sin descuentos por cantidad. PROHIBIDO usar calcular_usd o calcular_usd_desde_gyd para este servicio: la tasa es distinta. Para la entrega hacen falta tres datos de la persona que recibe: su telefono, una foto de su carnet de identidad y su direccion. Las provincias y municipios donde se entrega se hablan directamente con el equipo: PROHIBIDO decir si se entrega o no en un lugar concreto; ofrece pasar con un operador. El operador confirma tambien el horario de la entrega.',
  notas_internas = 'usuario 2026-09-28: entrega fisica de dolares en efectivo en Cuba. Tasa 290 GYD/USD, minimo 100 USD (29,000 GYD) por entrega, el negocio recibe siempre por MMG, sin descuentos. Datos de la entrega: telefono de quien recibe, foto del carnet y direccion. Provincias y municipios: se hablan directamente con el equipo (dicho por el otro admin). Falta saber si la 290 cambia a diario.',
  actualizado = now()
WHERE clave = 'efectivo_usd';
