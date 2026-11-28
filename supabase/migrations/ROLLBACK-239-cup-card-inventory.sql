-- ROLLBACK of 239_cup_card_inventory.sql: drops the CUP inventory functions and tables. Nothing else was created or replaced by 239.
-- DESTRUCTIVE: every card, lot and consumption row is lost with the tables (in phase 1 only what the owner typed in the admin page).
-- No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.crm_inventario_cup(uuid, boolean);
DROP FUNCTION IF EXISTS public.crm_eliminar_lote_cup(uuid);
DROP FUNCTION IF EXISTS public.crm_corregir_lote_cup(uuid, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.crm_cargar_lote_cup(uuid, uuid, numeric, numeric, text, timestamptz);
DROP FUNCTION IF EXISTS public.crm_guardar_tarjeta_cup(uuid, uuid, text, text, integer, numeric, boolean);
DROP TABLE IF EXISTS public.cup_lot_consumptions;
DROP TABLE IF EXISTS public.cup_lots;
DROP TABLE IF EXISTS public.cup_cards;
DROP FUNCTION IF EXISTS public.cup_cuba_day(timestamptz);
