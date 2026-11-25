// Marca del negocio para lo que se pide SIN sesión: ícono de la pestaña,
// app instalada en el celular y avisos. Cada cliente tiene su propia base
// (una cuenta), así que se lee la configuración de esa base con la llave
// de servidor. Si no hay o falla, queda la de Onlinefreedom.

import { supabaseAdmin } from "@/lib/automations/admin-client";
import { DEFAULT_NEGOCIO, leerNegocio, type NegocioConfig } from "@/lib/negocio/config";

let cache: { en: number; cfg: NegocioConfig } | null = null;
const VIGENCIA_MS = 5 * 60 * 1000;

export async function leerMarca(): Promise<NegocioConfig> {
  if (cache && Date.now() - cache.en < VIGENCIA_MS) return cache.cfg;
  let cfg = DEFAULT_NEGOCIO;
  try {
    const { data } = await supabaseAdmin()
      .from("negocio_config")
      .select("data")
      .order("updated_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (data) cfg = leerNegocio(data.data);
  } catch {
    // Sin base o sin llave: se usa la marca por defecto.
  }
  cache = { en: Date.now(), cfg };
  return cfg;
}
