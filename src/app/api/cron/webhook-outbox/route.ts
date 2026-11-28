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
import { runRetention } from '@/lib/storage/media-retention';

export const maxDuration = 60;

function adminClient(): SupabaseClient {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } },
  );
}

/** Objects deleted per cron tick: small on purpose, deletion is irreversible. */
const RETENTION_CAP_PER_TICK = 100;
const RETENTION_DAYS = 90;

/**
 * Retention adapters over the service client. Kept here, not in the core,
 * so the core stays testable without a Supabase client.
 */
function retentionDeps(db: SupabaseClient) {
  const bucket = db.storage.from('chat-media');
  return {
    storage: {
      list: async (prefix: string, { limit, offset }: { limit: number; offset: number }) => {
        const { data, error } = await bucket.list(prefix, { limit, offset });
        if (error) return { entries: [], hasMore: false, error: error.message };
        return {
          entries: (data ?? [])
            .filter((entry) => entry.id !== null)
            .map((entry) => ({
              name: entry.name,
              createdAt: entry.created_at ?? entry.updated_at ?? null,
            })),
          hasMore: (data ?? []).length === limit,
        };
      },
      remove: async (paths: string[]) => {
        const { error } = await bucket.remove(paths);
        return error ? { error: error.message } : {};
      },
    },
    db: {
      listAccountPrefixes: async () => {
        const { data, error } = await db.from('accounts').select('id');
        if (error) throw error;
        return (data ?? []).map((row) => `account-${(row as { id: string }).id}`);
      },
    },
  };
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
    // 90-day retention rides the same tick, after the sweeper, capped so a
    // single run can never delete a large slice by surprise.
    const { storage: retentionStorage, db: retentionDb } = retentionDeps(db);
    const retention = await runRetention(retentionStorage, retentionDb, {
      olderThanDays: RETENTION_DAYS,
      cap: RETENTION_CAP_PER_TICK,
    });
    return NextResponse.json({ ...result, media, retention });
  } catch (err) {
    console.error('[webhook outbox] worker failed:', err);
    return NextResponse.json({ error: 'worker failed' }, { status: 500 });
  }
}

export const GET = handle;
export const POST = handle;
