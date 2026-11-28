-- ROLLBACK of 355_usd_card_inventory.sql: drops the USD inventory functions and tables. Nothing else was created or replaced by 355.
-- DESTRUCTIVE: every card, lot and consumption row is lost with the tables. remittance_admin_audit rows written by
-- crm_ajustar_saldo_usd (table_name 'usd_cards') are kept as history. No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.crm_inventario_usd(uuid, boolean);
DROP FUNCTION IF EXISTS public.crm_ajustar_saldo_usd(uuid, numeric, text);
DROP FUNCTION IF EXISTS public.crm_eliminar_lote_usd(uuid);
DROP FUNCTION IF EXISTS public.crm_corregir_lote_usd(uuid, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.crm_cargar_lote_usd(uuid, uuid, numeric, numeric, timestamptz, text);
DROP FUNCTION IF EXISTS public.crm_guardar_tarjeta_usd(uuid, uuid, text, text, text, integer, numeric, boolean);
DROP TABLE IF EXISTS public.usd_lot_consumptions;
DROP TABLE IF EXISTS public.usd_lots;
DROP TABLE IF EXISTS public.usd_cards;
DROP FUNCTION IF EXISTS public.usd_cuba_month(timestamptz);
