// ============================================================
// GET/POST /api/cron/webhook-outbox
//
// The durable-delivery worker. pg_cron calls it every minute with the
// shared notify secret in `x-cerebro-secret`; it claims due rows
// (cerebro_webhook_outbox_reclamar), signs and sends each one, and
// records sent/skipped/pending/failed. It never handles customer data
// beyond the stored event payload.
// ============================================================

import { timingSafeEqual } from 'node:crypto';

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';

import { flushWebhookOutbox } from '@/lib/webhooks/outbox';
import { sweepPendingMedia } from '@/lib/whatsapp/media-sweeper';

export const maxDuration = 60;

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

async function handle(request: Request): Promise<Response> {
  const db = adminClient();
  const given = request.headers.get('x-cerebro-secret') ?? '';

  const { data, error } = await db
    .from('cerebro_config')
    .select('valor')
    .eq('clave', 'notify_secret')
    .maybeSingle();
  if (error) {
    console.error('[webhook outbox] secret read failed:', error);
    return NextResponse.json({ error: 'secret read failed' }, { status: 500 });
  }
  if (!data?.valor || !sameSecret(given, data.valor)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const result = await flushWebhookOutbox(db);
    // Inbound media that never settled rides the SAME tick, after the
    // outbox: no new cron job, route or secret. It is best-effort — the
    // outbox result is what this worker is responsible for.
    const media = await sweepPendingMedia();
    return NextResponse.json({ ...result, media });
  } catch (err) {
    console.error('[webhook outbox] worker failed:', err);
    return NextResponse.json({ error: 'worker failed' }, { status: 500 });
  }
}

export const GET = handle;
export const POST = handle;
