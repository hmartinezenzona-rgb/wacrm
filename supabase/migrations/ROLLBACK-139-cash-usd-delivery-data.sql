-- ROLLBACK 139: restore the efectivo_usd text from migration 137.
UPDATE cerebro_servicios SET
  hechos = 'Entrega de dolares en efectivo, fisicos, en Cuba. Tasa propia: 290 GYD por cada 1 USD (NO es la misma tasa de Zelle/Clasica/Tropical, que es 260). Minimo 100 USD por entrega, o sea minimo 29,000 GYD a depositar (100 x 290). El deposito se hace por MMG, igual que las demas vias. Sin descuentos por cantidad. PROHIBIDO usar calcular_usd o calcular_usd_desde_gyd para este servicio: la tasa es distinta. Un operador confirma el resto: datos de la entrega, zona y horario.',
  actualizado = now()
WHERE clave = 'efectivo_usd';
