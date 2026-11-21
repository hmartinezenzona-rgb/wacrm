import type { SupabaseClient } from "@supabase/supabase-js";
import { leerNegocio, type NegocioConfig } from "./config";

/** Lee la configuración de un negocio desde el servidor (rutas de avisos, etc.). */
export async function negocioDeCuenta(db: SupabaseClient, accountId: string): Promise<NegocioConfig> {
  const { data } = await db.from("negocio_config").select("data").eq("account_id", accountId).maybeSingle();
  return leerNegocio(data?.data);
}
