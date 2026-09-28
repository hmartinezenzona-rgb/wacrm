-- =====================================================================
-- 137 — Cash USD delivery in Cuba: a row in cerebro_servicios
--
-- WHY
--   New service reported by the user on 2026-09-28: physical USD cash
--   delivered in Cuba. It is NOT Zelle, Clasica or Tropical (those pay a
--   card/account; this hands over paper dollars) and it does NOT share
--   their rate: 290 GYD per USD here, vs 260 GYD per USD for the other
--   three (see VIA USD in the Cerebro prompt). Today the bot has no row
--   for it and no way to answer without quoting it wrong — see
--   odd/tasks/cash-usd-service-info.md.
--
-- WHAT
--   One new row, clave='efectivo_usd', in the same table the other
--   services (combos, recargas, visa, traduccion, mexico) already use.
--   `activo=true` so cerebro_servicio_get() returns it; `requiere_humano
--   =true` so the prompt's existing OTROS SERVICIOS rule ("Con
--   requiere_humano=true, el mensaje termina con: 'Si quiere, le paso con
--   un operador.'") applies with NO prompt change needed for that part.
--   `hechos` states ONLY the facts given by the user: physical cash in
--   Cuba, 290 GYD/USD, minimum 100 USD (29,000 GYD) per delivery, deposit
--   by MMG as usual, no discounts, an operator confirms the rest. It also
--   repeats the "never calcular_usd" rule inline (same pattern as 054's
--   "PROHIBIDO ofrecer rebajas" baked into `hechos`, not just the
--   prompt), so the fact is enforced even if consultar_servicio is ever
--   called from a path this migration's prompt change (see the Cerebro
--   staging/prod deploy, not tracked here) does not cover.
--
--   Nothing else in this table changes: no existing `clave` is touched,
--   no function is redefined. cerebro_servicio_get('efectivo_usd')
--   (049/122) needs no change: its WHERE clause already matches any
--   activo row by clave or by nombre ILIKE, and its CASE branches are
--   specific to clave='recargas'.
--
-- OUT OF SCOPE (see odd/tasks/cash-usd-service-info.md)
--   A full cash "via" (own tasas row, calculators, marcar_destino_usd
--   ('efectivo'), panel support) needs product answers first: does 290
--   change daily, which beneficiary data, which provinces. This is data
--   only, read by consultar_servicio('efectivo_usd') from the prompt.
--
-- IDEMPOTENT: ON CONFLICT (clave) DO UPDATE, safe to re-run.
-- ROLLBACK: ROLLBACK-137-cash-usd-service.sql
-- =====================================================================

INSERT INTO cerebro_servicios (clave, nombre, activo, hechos, requiere_humano, notas_internas, actualizado)
VALUES (
  'efectivo_usd',
  'Entrega de dolares en efectivo en Cuba',
  true,
  'Entrega de dolares en efectivo, fisicos, en Cuba. Tasa propia: 290 GYD por cada 1 USD (NO es la misma tasa de Zelle/Clasica/Tropical, que es 260). Minimo 100 USD por entrega, o sea minimo 29,000 GYD a depositar (100 x 290). El deposito se hace por MMG, igual que las demas vias. Sin descuentos por cantidad. PROHIBIDO usar calcular_usd o calcular_usd_desde_gyd para este servicio: la tasa es distinta. Un operador confirma el resto: datos de la entrega, zona y horario.',
  true,
  'usuario 2026-09-28: nuevo servicio, entrega fisica de dolares en efectivo en Cuba. Tasa 290 GYD/USD, minimo 100 USD (29,000 GYD) por entrega, deposito por MMG, sin descuentos. Un operador confirma datos de entrega, zona y horario. Fuera de alcance por ahora (ver odd/tasks/cash-usd-service-info.md): via USD completa con tasa propia en cerebro_config/tasas, calculadoras propias, marcar_destino_usd(''efectivo''), panel -- necesita respuestas de producto primero (si 290 cambia a diario, que datos de beneficiario, que provincias).',
  now()
)
ON CONFLICT (clave) DO UPDATE SET
  nombre = EXCLUDED.nombre,
  activo = EXCLUDED.activo,
  hechos = EXCLUDED.hechos,
  requiere_humano = EXCLUDED.requiere_humano,
  notas_internas = EXCLUDED.notas_internas,
  actualizado = now();

-- =====================================================================
-- COMO SE PROBO (staging, 2026-09-28)
--
--   SELECT * FROM cerebro_servicio_get('efectivo_usd');
--   -> una fila: nombre 'Entrega de dolares en efectivo en Cuba',
--      hechos con 290 / 100 USD / 29,000 GYD / MMG / sin descuentos,
--      requiere_humano=true.
-- =====================================================================
