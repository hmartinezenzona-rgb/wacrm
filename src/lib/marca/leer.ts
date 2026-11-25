// Marca del negocio para lo que se pide SIN sesión: ícono de la pestaña,
// app instalada en el celular y avisos. Cada cliente tiene su propia base;
// la función pública marca_publica() (migración 337) entrega solo nombre,
// tema e ícono. Si no hay o falla, queda la de Onlinefreedom.

import { createClient } from "@supabase/supabase-js";
import { DEFAULT_NEGOCIO, leerNegocio, type NegocioConfig } from "@/lib/negocio/config";

let cache: { en: number; cfg: NegocioConfig } | null = null;
const VIGENCIA_MS = 5 * 60 * 1000;

export async function leerMarca(): Promise<NegocioConfig> {
  if (cache && Date.now() - cache.en < VIGENCIA_MS) return cache.cfg;
  let cfg = DEFAULT_NEGOCIO;
  try {
    const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      auth: { persistSession: false },
    });
    const { data, error } = await supabase.rpc("marca_publica");
    if (!error && data) cfg = leerNegocio(data);
  } catch {
    // Sin base: se usa la marca por defecto.
  }
  cache = { en: Date.now(), cfg };
  return cfg;
}
