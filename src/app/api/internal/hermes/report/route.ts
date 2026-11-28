// ============================================================
// POST /api/internal/hermes/report
//
// Delivery door for the Hermes daily report. Hermes (a local one-shot
// agent) builds the day's report from the production database and posts
// the finished text here; this route queues it for the admin through the
// existing message outbox (cerebro_outbox_encolar), which already handles
// the 24-hour window and the notifier's template fallback. Hermes never
// talks to WhatsApp directly.
//
// Auth: the shared notify secret in `x-cerebro-secret` (same as the
// pg_cron workers), compared in constant time.
//
// Body: { text: string, phone?: string }. `phone` defaults to the owner's
// number; the conversation must already exist for that phone.
// ============================================================

import { timingSafeEqual } from 'node:crypto';

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';

export const maxDuration = 30;

/** The owner's admin number (contact "humbe"). */
const DEFAULT_PHONE = '5219622896918';

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
    console.error('[hermes report] secret read failed:', configError);
    return NextResponse.json({ error: 'secret read failed' }, { status: 500 });
  }
  if (!config?.valor || !sameSecret(given, config.valor)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const body = (await request.json().catch(() => null)) as
    | { text?: unknown; phone?: unknown }
    | null;
  const text = typeof body?.text === 'string' ? body.text.trim() : '';
  const phone = typeof body?.phone === 'string' && body.phone.trim()
    ? body.phone.replace(/\D/g, '')
    : DEFAULT_PHONE;

  if (!text) {
    return NextResponse.json({ error: 'text is required' }, { status: 400 });
  }
  if (text.length > 3500) {
    // WhatsApp caps a single message at 4096 characters; leave room for the header.
    return NextResponse.json({ error: 'text is too long (max 3500)' }, { status: 400 });
  }

  const { data: contact } = await db
    .from('contacts')
    .select('id')
    .eq('phone', phone)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!contact) {
    return NextResponse.json({ error: 'contact not found for that phone' }, { status: 404 });
  }

  const { data: conversation } = await db
    .from('conversations')
    .select('id')
    .eq('contact_id', contact.id)
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!conversation) {
    return NextResponse.json({ error: 'conversation not found for that contact' }, { status: 404 });
  }

  const day = new Date().toISOString().slice(0, 10);
  const { data: queued, error: queueError } = await db.rpc('cerebro_outbox_encolar', {
    p_conversation_id: conversation.id,
    p_telefono: phone,
    p_texto: text,
    p_operation_id: null,
    p_execution_id: `hermes-informe-${day}`,
  });
  if (queueError) {
    console.error('[hermes report] enqueue failed:', queueError);
    return NextResponse.json({ error: 'enqueue failed' }, { status: 500 });
  }

  const result = Array.isArray(queued) ? queued[0] : queued;
  return NextResponse.json({ ok: true, result });
}
