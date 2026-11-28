// ============================================================
// Sweeper for inbound media that never settled.
//
// Slice 6a writes the message first and downloads afterwards. If the
// process dies between the two — a deploy, a crash, a lost ACK — the row
// stays `pending` forever and the panel shows "Descargando archivo…"
// with nothing coming.
//
// This runs inside the existing webhook-outbox cron: one call claims the
// stale rows through `crm_media_reclamar` (which also settles the ones
// that can never succeed), downloads them, and runs the bot tail for the
// ones still inside the 24 h window in which a late reply makes sense.
//
// Safe to re-run: the claim function bumps `media_claimed_at`, so a
// second run a moment later finds nothing to do.
// ============================================================

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { decrypt } from '@/lib/whatsapp/encryption';
import { settleInboundMedia } from '@/lib/whatsapp/inbound-media';
import { runInboundTail } from '@/lib/whatsapp/inbound-tail';

/** How long a claimed row may look busy before the sweeper takes it. */
export const SWEEP_CLAIM_LIMIT = 5;

/** After this, a late bot reply is worse than none: settle, do not dispatch. */
export const SWEEP_TAIL_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Default wall-clock budget for one cron tick. */
export const SWEEP_BUDGET_MS = 20_000;

export interface SweepResult {
  /** Rows claimed for a retry. */
  retried: number;
  settledReady: number;
  settledFailed: number;
  /** Rows whose bot tail ran. */
  dispatched: number;
  /** Rows skipped because they are older than the tail window. */
  skippedStale: number;
}

interface ClaimedRow {
  id: string;
  conversation_id: string;
  message_id: string | null;
  media_url: string | null;
  content_type: string | null;
  content_text: string | null;
  created_at: string;
  media_attempts: number | null;
  accion: 'reintentar' | 'fallida';
}

/** `/api/whatsapp/media/<id>` → `<id>`. */
export function mediaIdFromUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const match = /\/api\/whatsapp\/media\/([^/?#]+)/.exec(url);
  return match ? match[1] : null;
}

interface AccountContext {
  accountId: string;
  contactId: string;
  accessToken: string;
  configUserId: string;
}

/** Account id + decrypted token for the conversation that owns the row. */
async function accountContextFor(
  supabase: ReturnType<typeof supabaseAdmin>,
  conversationId: string,
  cache: Map<string, AccountContext | null>,
): Promise<AccountContext | null> {
  const { data: conversation } = await supabase
    .from('conversations')
    .select('account_id, contact_id')
    .eq('id', conversationId)
    .maybeSingle();
  const conv = conversation as { account_id?: string; contact_id?: string } | null;
  const accountId = conv?.account_id;
  if (!accountId) return null;
  if (cache.has(accountId)) return cache.get(accountId) ?? null;

  const { data: config } = await supabase
    .from('whatsapp_config')
    .select('access_token, user_id')
    .eq('account_id', accountId)
    .maybeSingle();
  const row = config as { access_token?: string; user_id?: string } | null;
  if (!row?.access_token) {
    cache.set(accountId, null);
    return null;
  }
  const context: AccountContext = {
    accountId,
    contactId: conv?.contact_id ?? '',
    accessToken: decrypt(row.access_token),
    configUserId: row.user_id ?? '',
  };
  cache.set(accountId, context);
  return context;
}

export interface SweepOptions {
  budgetMs?: number;
  /** Injectable for tests. */
  now?: () => number;
}

/**
 * Settle what can be settled, dispatch what still deserves a reply, and
 * stop when the budget runs out. Never throws: the cron must keep going.
 */
export async function sweepPendingMedia(
  options: SweepOptions = {},
): Promise<SweepResult> {
  const result: SweepResult = {
    retried: 0,
    settledReady: 0,
    settledFailed: 0,
    dispatched: 0,
    skippedStale: 0,
  };
  const budgetMs = options.budgetMs ?? SWEEP_BUDGET_MS;
  const now = options.now ?? Date.now;
  const startedAt = now();
  const supabase = supabaseAdmin();
  const contexts = new Map<string, AccountContext | null>();

  try {
    const { data, error } = await supabase.rpc('crm_media_reclamar', {
      p_limit: SWEEP_CLAIM_LIMIT,
    });
    if (error) {
      console.error('[media-sweeper] claim failed:', error.message);
      return result;
    }

    for (const raw of (data ?? []) as ClaimedRow[]) {
      if (now() - startedAt > budgetMs) break;

      if (raw.accion === 'fallida') {
        result.settledFailed++;
      } else {
        result.retried++;
        const context = await accountContextFor(supabase, raw.conversation_id, contexts);
        const mediaId = mediaIdFromUrl(raw.media_url);
        if (context && mediaId) {
          const outcome = await settleInboundMedia({
            messageId: raw.id,
            mediaId,
            accessToken: context.accessToken,
            accountId: context.accountId,
            contentType: raw.content_type ?? 'image',
          });
          if (outcome === 'ready') result.settledReady++;
          else result.settledFailed++;
        } else {
          // No token or no media id: leave it for the next sweep rather than
          // guessing; the claim already bumped media_claimed_at.
          console.warn('[media-sweeper] sin contexto para', raw.id);
          continue;
        }
      }

      const createdAt = Date.parse(raw.created_at);
      if (Number.isFinite(createdAt) && now() - createdAt > SWEEP_TAIL_WINDOW_MS) {
        result.skippedStale++;
        continue;
      }
      if (!raw.message_id) {
        result.skippedStale++;
        continue;
      }

      const context = await accountContextFor(supabase, raw.conversation_id, contexts);
      if (!context) {
        result.skippedStale++;
        continue;
      }
      await runInboundTail({
        accountId: context.accountId,
        configOwnerUserId: context.configUserId,
        contactId: context.contactId,
        conversationId: raw.conversation_id,
        message: {
          id: raw.message_id,
          type: raw.content_type ?? 'image',
        },
        contentType: raw.content_type ?? 'image',
        contentText: raw.content_text,
        interactiveReplyId: null,
        isFirstInboundMessage: false,
        contactWasCreated: false,
      });
      result.dispatched++;
    }
  } catch (thrown) {
    console.error(
      '[media-sweeper] failed:',
      thrown instanceof Error ? thrown.message : String(thrown),
    );
  }

  return result;
}
