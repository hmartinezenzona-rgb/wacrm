// ============================================================
// GET /api/hermes/vistazo — the idea cards' figures. Admin only, read-only.
// ============================================================

import { NextResponse } from 'next/server';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { requireRole, toErrorResponse } from '@/lib/auth/account';
import { buildVistazo } from '@/lib/hermes/vistazo';
import { createClient as createSessionClient } from '@/lib/supabase/server';

export const runtime = 'nodejs';
export const maxDuration = 30;

function adminClient(): SupabaseClient {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } },
  );
}

export async function GET(): Promise<Response> {
  try {
    await requireRole('admin');
  } catch (err) {
    return toErrorResponse(err);
  }

  try {
    const vistazo = await buildVistazo(adminClient(), await createSessionClient());
    return NextResponse.json(vistazo, {
      headers: { 'Cache-Control': 'private, max-age=60' },
    });
  } catch (err) {
    console.error('[hermes vistazo] failed:', err);
    return NextResponse.json({ error: 'No se pudo leer el resumen.' }, { status: 500 });
  }
}
