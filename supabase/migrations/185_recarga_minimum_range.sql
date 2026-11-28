-- =====================================================================
-- 185 — the top of the recarga deposit minimum range, for the bot's context (staging; production 2026-10-02)
--
-- odd/tasks/reparto-guards.md, T3 (finding F3). The owner's deposit minimums (2026-10-02): recargas
-- go from 5,200 GYD (500 CUP promotion) to 6,200 GYD (600 CUP promotion). 170 stored only the lower
-- one, which cerebro_minimo_gyd keeps using as the money rule. This key is read only by the n8n
-- `Contexto conversacion` node (gate 82), which tells the model the whole range.
--
-- ROLLBACK: ROLLBACK-185-recarga-minimum-range.sql
-- =====================================================================

INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('minimo_gyd_recarga_hasta', '6200', 'Tope del rango del deposito minimo en GYD para una recarga (promocion de 600 CUP); solo informativo para el bot, la regla de dinero usa minimo_gyd_recarga (185).')
ON CONFLICT (clave) DO NOTHING;
