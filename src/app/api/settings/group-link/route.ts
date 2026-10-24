import { NextResponse } from 'next/server';

import { getCurrentAccount, requireRole, toErrorResponse } from '@/lib/auth/account';
import { supabaseAdmin } from '@/lib/automations/admin-client';
import {
  GRUPO_URL_CLAVE,
  GRUPO_URL_POR_DEFECTO,
} from '@/lib/settings/group-link';

function urlValida(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:';
  } catch {
    return false;
  }
}

/** Current group link (null = using the built-in default). */
export async function GET() {
  try {
    await getCurrentAccount();
    const { data, error } = await supabaseAdmin()
      .from('cerebro_config')
      .select('valor')
      .eq('clave', GRUPO_URL_CLAVE)
      .maybeSingle();
    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }
    return NextResponse.json({
      url: data?.valor?.trim() || null,
      default_url: GRUPO_URL_POR_DEFECTO,
    });
  } catch (err) {
    return toErrorResponse(err);
  }
}

/** Admin+: set the group link; an empty url restores the default. */
export async function PUT(request: Request) {
  try {
    await requireRole('admin');
  } catch (err) {
    return toErrorResponse(err);
  }

  const body = await request.json().catch(() => null);
  const url = typeof body?.url === 'string' ? body.url.trim() : '';
  if (url && !urlValida(url)) {
    return NextResponse.json(
      { error: 'La URL debe empezar por http:// o https://' },
      { status: 400 },
    );
  }

  const admin = supabaseAdmin();
  const { error } = url
    ? await admin.from('cerebro_config').upsert(
        {
          clave: GRUPO_URL_CLAVE,
          valor: url,
          descripcion: 'Destino de /grupo: invitación al grupo de WhatsApp',
          actualizado: new Date().toISOString(),
        },
        { onConflict: 'clave' },
      )
    : await admin.from('cerebro_config').delete().eq('clave', GRUPO_URL_CLAVE);

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({
    url: url || null,
    default_url: GRUPO_URL_POR_DEFECTO,
  });
}
