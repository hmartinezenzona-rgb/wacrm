import { supabaseAdmin } from '@/lib/automations/admin-client';

// Destination of the public /grupo redirect (the WhatsApp template button).
// Stored in cerebro_config as `grupo_url` so the owner can change the group
// from Settings without touching code or re-approving the template.
export const GRUPO_URL_POR_DEFECTO =
  'https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81';

export const GRUPO_URL_CLAVE = 'grupo_url';

/** Configured group link, or the built-in default when unset or unreadable. */
export async function leerGrupoUrl(): Promise<string> {
  try {
    const { data } = await supabaseAdmin()
      .from('cerebro_config')
      .select('valor')
      .eq('clave', GRUPO_URL_CLAVE)
      .maybeSingle();
    const valor = (data?.valor ?? '').trim();
    return valor || GRUPO_URL_POR_DEFECTO;
  } catch {
    // A config read must never break the redirect: fall back to the default.
    return GRUPO_URL_POR_DEFECTO;
  }
}
