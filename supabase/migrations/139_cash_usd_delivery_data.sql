-- =====================================================================
-- 139 — Cash USD delivery: the data the delivery needs
--
-- WHY
--   The user confirmed on 2026-09-28 which data a cash USD delivery in
--   Cuba needs: the recipient's phone, a photo of the recipient's ID card
--   (carnet) and the recipient's address. The user also confirmed the rest
--   of the 137 facts (the business always receives by MMG; no discounts).
--
-- WHAT
--   Updates only `hechos` and `notas_internas` of the `efectivo_usd` row.
--   Same facts as 137 plus the delivery data. requiere_humano stays true.
--
-- IDEMPOTENT: a plain UPDATE of one row, safe to re-run.
-- ROLLBACK: ROLLBACK-139-cash-usd-delivery-data.sql (restores the 137 text)
-- =====================================================================

UPDATE cerebro_servicios SET
  hechos = 'Entrega de dolares en efectivo, fisicos, en Cuba. Tasa propia: 290 GYD por cada 1 USD (NO es la misma tasa de Zelle/Clasica/Tropical, que es 260). Minimo 100 USD por entrega, o sea minimo 29,000 GYD a depositar (100 x 290). El deposito se hace por MMG, igual que las demas vias. Sin descuentos por cantidad. PROHIBIDO usar calcular_usd o calcular_usd_desde_gyd para este servicio: la tasa es distinta. Para la entrega hacen falta tres datos de la persona que recibe: su telefono, una foto de su carnet de identidad y su direccion. Un operador confirma el resto: zona y horario de la entrega.',
  notas_internas = 'usuario 2026-09-28: entrega fisica de dolares en efectivo en Cuba. Tasa 290 GYD/USD, minimo 100 USD (29,000 GYD) por entrega, el negocio recibe siempre por MMG, sin descuentos. Datos de la entrega: telefono de quien recibe, foto del carnet y direccion. Fuera de alcance por ahora: via USD completa (tasa propia, calculadora, marcar_destino_usd, panel); falta saber si la 290 cambia a diario y a que provincias llega.',
  actualizado = now()
WHERE clave = 'efectivo_usd';
