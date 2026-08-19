// ============================================================
// The draft map: which deal has which proof prepared.
//
// Extracted from the board so the two things that are easy to get
// wrong can be tested without a browser:
//
//   1. Every blob: URL that is created is eventually revoked —
//      on replace, on remove, on send, on unmount. A leaked object
//      URL pins the whole file in memory for the life of the tab,
//      and these are multi-megabyte screenshots.
//
//   2. A draft is only ever reachable through its own deal id.
//      Deal A's transfer screenshot reaching deal B's customer is
//      the worst failure this feature can produce.
//
// `createUrl` / `revokeUrl` are injected rather than called
// directly: `URL.createObjectURL` does not exist under vitest's
// `node` environment, and passing them in is what lets the tests
// count the revocations.
// ============================================================

import type { DeliveryProofDraft, ProofImageKind } from "./delivery-proof";

export type ProofDrafts = ReadonlyMap<string, DeliveryProofDraft>;

/** Browser object-URL functions, injected for testability. */
export interface ObjectUrls {
  createUrl: (file: File) => string;
  revokeUrl: (url: string) => void;
}

/**
 * Attach a file to a deal, replacing whatever was there.
 *
 * A replacement revokes the preview it replaces — swapping the
 * screenshot three times must not leave three blobs alive — and keeps
 * the note already typed, because re-typing it would be a small,
 * repeated annoyance for no reason.
 */
export function putProofDraft(
  drafts: ProofDrafts,
  dealId: string,
  file: File,
  kind: ProofImageKind,
  urls: ObjectUrls,
): ProofDrafts {
  const previous = drafts.get(dealId);
  if (previous) urls.revokeUrl(previous.previewUrl);

  const next = new Map(drafts);
  next.set(dealId, {
    dealId,
    file,
    kind,
    previewUrl: urls.createUrl(file),
    caption: previous?.caption ?? "",
  });
  return next;
}

/**
 * Drop a deal's draft and revoke its preview. A no-op — returning the
 * same map, so React skips the re-render — when there is nothing there.
 */
export function removeProofDraft(
  drafts: ProofDrafts,
  dealId: string,
  urls: Pick<ObjectUrls, "revokeUrl">,
): ProofDrafts {
  const existing = drafts.get(dealId);
  if (!existing) return drafts;
  urls.revokeUrl(existing.previewUrl);
  const next = new Map(drafts);
  next.delete(dealId);
  return next;
}

/** Edit the note. No object URLs change, so nothing is revoked. */
export function setProofCaption(
  drafts: ProofDrafts,
  dealId: string,
  caption: string,
): ProofDrafts {
  const existing = drafts.get(dealId);
  if (!existing) return drafts;
  const next = new Map(drafts);
  next.set(dealId, { ...existing, caption });
  return next;
}

/**
 * Record that the image reached the customer.
 *
 * Called only after a stage update fails on an already-sent proof.
 * From then on the draft is a "retry the stage" token: `deliverDeal`
 * sees `sentWamid` and skips straight to the update.
 */
export function markProofSent(
  drafts: ProofDrafts,
  dealId: string,
  wamid: string | undefined,
): ProofDrafts {
  const existing = drafts.get(dealId);
  if (!existing) return drafts;
  const next = new Map(drafts);
  // A missing wamid still has to flip the flag — the send succeeded,
  // and re-sending is the thing being prevented, not the logging.
  next.set(dealId, { ...existing, sentWamid: wamid || "sent" });
  return next;
}

/** Revoke every preview. For unmount, where the whole map goes away. */
export function revokeAllPreviews(
  drafts: ProofDrafts,
  urls: Pick<ObjectUrls, "revokeUrl">,
): void {
  for (const draft of drafts.values()) urls.revokeUrl(draft.previewUrl);
}

/**
 * Drop drafts whose deal is no longer sitting in "Lista para transferir".
 *
 * The board is live: n8n, another agent, or the same person in another
 * tab can move a deal at any moment, and Realtime refreshes the list
 * underneath a prepared proof. A draft left attached to a deal that
 * has already moved on is at best a stale paperclip and at worst a
 * screenshot waiting to be sent into a closed remittance.
 *
 * Two things are deliberately kept:
 *
 *   · `keepDealId` — the delivery this tab is running right now. We are
 *     the ones moving that deal to Entregada; pruning it mid-flight
 *     would delete the draft (and its `sentWamid`) out from under the
 *     send.
 *
 *   · any draft with `sentWamid` — the image is already with the
 *     customer and the draft is now a "retry the stage" token. Losing
 *     it is what would allow a second send.
 *
 * An empty `deals` list is treated as "not loaded yet", not as "every
 * deal is gone": the first render has no deals, and wiping an
 * operator's prepared screenshot on a transient empty list would be a
 * worse bug than keeping a stale one. A stale draft cannot be sent
 * anyway — `deliverDeal` re-reads the stage before it uploads.
 */
export function pruneStaleDrafts(
  drafts: ProofDrafts,
  deals: readonly { id: string; stage_id: string }[],
  proofStageId: string,
  urls: Pick<ObjectUrls, "revokeUrl">,
  opts: { keepDealId?: string | null } = {},
): ProofDrafts {
  if (drafts.size === 0 || deals.length === 0) return drafts;

  const stageByDeal = new Map(deals.map((d) => [d.id, d.stage_id]));
  const doomed: string[] = [];

  for (const [dealId, draft] of drafts) {
    if (dealId === opts.keepDealId) continue;
    if (draft.sentWamid) continue;
    // A deal missing from the board is left alone too: the board's
    // own query filters by window and status, so "absent" does not
    // reliably mean "gone".
    const stage = stageByDeal.get(dealId);
    if (stage === undefined) continue;
    if (stage !== proofStageId) doomed.push(dealId);
  }

  if (doomed.length === 0) return drafts;

  const next = new Map(drafts);
  for (const dealId of doomed) {
    const draft = next.get(dealId);
    if (draft) urls.revokeUrl(draft.previewUrl);
    next.delete(dealId);
  }
  return next;
}
