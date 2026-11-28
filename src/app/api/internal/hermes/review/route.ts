// ============================================================
// POST /api/internal/hermes/review
//
// Internal door for the nightly Cerebro review. The CRM server adds the
// Hermes key and asks the CRM Hermes (HERMES_API_URL, OpenAI-compatible)
// to review a prompt. The nightly job never sees HERMES_API_KEY.
//
// Auth: the shared notify secret in `x-cerebro-secret` (same as the
// pg_cron workers and /api/internal/hermes/report), constant time.
//
// Body: { prompt: string } (max 300k chars). Returns { content: string }.
// ============================================================

import { timingSafeEqual } from 'node:crypto';

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';

export const runtime = 'nodejs';
export const maxDuration = 600;

const MAX_PROMPT = 300_000;

function adminClient(): SupabaseClient {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } },
  );
}

function sameSecret(given: string, expected: string): boolean {
  const a = Buffer.from(given, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (!a.length || a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export async function POST(request: Request): Promise<Response> {
  const db = adminClient();
  const given = request.headers.get('x-cerebro-secret') ?? '';

  const { data: config, error: configError } = await db
    .from('cerebro_config')
    .select('valor')
    .eq('clave', 'notify_secret')
    .maybeSingle();
  if (configError) {
    console.error('[hermes review] secret read failed:', configError);
    return NextResponse.json({ error: 'secret read failed' }, { status: 500 });
  }
  if (!config?.valor || !sameSecret(given, config.valor)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const body = (await request.json().catch(() => null)) as { prompt?: unknown } | null;
  const prompt = typeof body?.prompt === 'string' ? body.prompt : '';
  if (!prompt.trim()) {
    return NextResponse.json({ error: 'prompt is required' }, { status: 400 });
  }
  if (prompt.length > MAX_PROMPT) {
    return NextResponse.json({ error: `prompt is too long (max ${MAX_PROMPT})` }, { status: 413 });
  }

  const base = process.env.HERMES_API_URL;
  const key = process.env.HERMES_API_KEY;
  if (!base || !key) {
    return NextResponse.json(
      { error: 'Hermes no está configurado en el panel (HERMES_API_URL / HERMES_API_KEY).' },
      { status: 503 },
    );
  }

  let response: Response;
  try {
    response = await fetch(`${base.replace(/\/$/, '')}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: process.env.HERMES_API_MODEL || 'hermes',
        messages: [{ role: 'user', content: prompt }],
        stream: false,
      }),
      signal: AbortSignal.timeout(590_000),
    });
  } catch (err) {
    console.error('[hermes review] request failed:', err);
    return NextResponse.json({ error: 'No se pudo contactar a Hermes.' }, { status: 502 });
  }

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    console.error('[hermes review] upstream error', response.status, detail.slice(0, 300));
    return NextResponse.json({ error: `Hermes respondió ${response.status}.` }, { status: 502 });
  }

  const data = (await response.json().catch(() => null)) as
    | { choices?: Array<{ message?: { content?: unknown } }> }
    | null;
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== 'string') {
    return NextResponse.json({ error: 'Hermes devolvió una respuesta vacía.' }, { status: 502 });
  }
  return NextResponse.json({ content });
}
