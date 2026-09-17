// ============================================================
// Prefetch-on-hover for the in-chat operations panel (panel-26,
// readiness). Measured: `crm_operaciones_de_conversacion` costs 1.3ms
// and `crm_comprobantes_de_operacion` 2.4ms at the database — the HTTP
// round trip + auth + mount is what makes the panel feel late, and that
// cost can't be removed, only moved earlier. This module fires the
// EXACT GET the container's own `load()` issues (route.ts, single round
// trip since `receiptsByOperationId` was folded in) the moment a user's
// mouse or keyboard focus lands on a conversation row, so the response
// is often already in hand by the time they click.
//
// Self-gating: the route 404s for a caller without the `operations_panel`
// beta flag (contact-sidebar.tsx:45 gates the UI, route.ts gates the
// data). Rather than have the conversation list — which renders for
// every user, flagged or not — know about that flag, the FIRST 404 this
// module sees flips a module-level switch that makes every later call a
// no-op for the rest of the session: one wasted request total, not one
// per hover.
// ============================================================

import type { ConversationOperationsRead } from "./types";

const TTL_MS = 30_000;
const MAX_ENTRIES = 10;

interface CacheEntry {
  data: ConversationOperationsRead;
  expiresAt: number;
}

const cache = new Map<string, CacheEntry>();

// Tracks ids with a request currently in flight so a hover that fires
// several times in a row (mouseenter + focus, or a jittery cursor)
// coalesces into the one request already underway.
const inFlight = new Set<string>();

// Flips permanently on the first 404 and never resets within a page
// session — a fresh navigation/reload re-checks. See module header.
let disabled = false;

function rememberEntry(conversationId: string, data: ConversationOperationsRead): void {
  // Eviction only needs to consider genuinely new ids — refreshing an
  // id already cached doesn't grow the map, so it never needs to evict.
  if (!cache.has(conversationId) && cache.size >= MAX_ENTRIES) {
    const oldestId = cache.keys().next().value;
    if (oldestId !== undefined) cache.delete(oldestId);
  }
  cache.set(conversationId, { data, expiresAt: Date.now() + TTL_MS });
}

/**
 * Fire-and-forget: fires the same `GET /api/remittance-operations`
 * request `operations-panel-container.tsx`'s `load()` makes, for
 * `conversationId`, and caches a successful result. Never throws and
 * never returns a promise — callers (a row's `onMouseEnter`/`onFocus`)
 * have nothing to await or catch. Any failure (network error, non-2xx
 * other than 404, a 404 itself) just means no cache entry gets written;
 * the panel container's existing fetch-on-mount is the fallback either
 * way, so a failed prefetch costs nothing beyond the one wasted request.
 */
export function prefetchConversationOperations(conversationId: string): void {
  if (disabled) return;
  if (inFlight.has(conversationId)) return;
  inFlight.add(conversationId);

  fetch(`/api/remittance-operations?conversationId=${conversationId}`, {
    cache: "no-store",
  })
    .then(async (response) => {
      if (response.status === 404) {
        // No `operations_panel` beta flag — gate every later call too,
        // so a user without the flag wastes exactly one request.
        disabled = true;
        return;
      }
      if (!response.ok) return;
      const data = (await response.json()) as ConversationOperationsRead;
      rememberEntry(conversationId, data);
    })
    .catch(() => {
      // Convenience only — never surface an error for a prefetch.
    })
    .finally(() => {
      inFlight.delete(conversationId);
    });
}

/**
 * Returns the cached read for `conversationId` if one exists and is
 * still within the 30s TTL, else `null`. A miss (never prefetched,
 * expired, or the prefetch failed/was gated) looks identical to the
 * caller on purpose: the panel container's existing `load()` is the
 * fallback for every one of those cases.
 */
export function readPrefetchedConversationOperations(
  conversationId: string,
): ConversationOperationsRead | null {
  const entry = cache.get(conversationId);
  if (!entry) return null;
  if (Date.now() >= entry.expiresAt) {
    cache.delete(conversationId);
    return null;
  }
  return entry.data;
}

/** Test-only: clears cache/in-flight/gate state between tests — mirrors
 *  `__resetRateLimitForTests` in `rate-limit.ts`. Never call from app
 *  code. */
export function __resetPanelPrefetchForTests(): void {
  cache.clear();
  inFlight.clear();
  disabled = false;
}
