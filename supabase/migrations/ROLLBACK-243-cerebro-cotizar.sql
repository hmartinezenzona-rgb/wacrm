-- ROLLBACK of 243_cerebro_cotizar.sql: drops public.cerebro_cotizar(uuid, numeric, text, text, text, text).
--
-- 243 is purely additive -- it creates that one function and alters nothing else -- so this rollback loses no data and restores no previous
-- body: there was none. The four calculator tools (calcular_envio, calcular_inverso, calcular_usd, calcular_usd_desde_gyd) live in the n8n
-- workflow and are untouched by 243, so they keep working before and after this rollback.
--
-- ORDER MATTERS: if the n8n workflow has already been switched to the merged `cotizar` tool, PUT the saved pre-change workflow JSON back
-- FIRST and only then run this file. Dropping the function while a live tool still calls it leaves the agent unable to quote at all.
-- No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.cerebro_cotizar(uuid, numeric, text, text, text, text);
