-- ROLLBACK 140: restore the efectivo_usd text from migration 139.
UPDATE cerebro_servicios SET
  hechos = 'Entrega de dolares en efectivo, fisicos, en Cuba. Tasa propia: 290 GYD por cada 1 USD (NO es la misma tasa de Zelle/Clasica/Tropical, que es 260). Minimo 100 USD por entrega, o sea minimo 29,000 GYD a depositar (100 x 290). El deposito se hace por MMG, igual que las demas vias. Sin descuentos por cantidad. PROHIBIDO usar calcular_usd o calcular_usd_desde_gyd para este servicio: la tasa es distinta. Para la entrega hacen falta tres datos de la persona que recibe: su telefono, una foto de su carnet de identidad y su direccion. Un operador confirma el resto: zona y horario de la entrega.',
  notas_internas = 'usuario 2026-09-28: entrega fisica de dolares en efectivo en Cuba. Tasa 290 GYD/USD, minimo 100 USD (29,000 GYD) por entrega, el negocio recibe siempre por MMG, sin descuentos. Datos de la entrega: telefono de quien recibe, foto del carnet y direccion. Fuera de alcance por ahora: via USD completa (tasa propia, calculadora, marcar_destino_usd, panel); falta saber si la 290 cambia a diario y a que provincias llega.',
  actualizado = now()
WHERE clave = 'efectivo_usd';
