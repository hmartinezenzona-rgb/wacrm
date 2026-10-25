// ============================================================
// One-shot handoff for "open this conversation in the inbox".
//
// Deep links used to carry the conversation id in the URL (`/inbox?c=<id>`).
// Next.js re-publishes the last search string of a route on every client
// navigation back to it, so once /inbox had been visited with `?c=`, the
// parameter came back even after being cleared and the thread reopened by
// itself. The id now travels in sessionStorage instead: written by whoever
// wants to open a thread, read and removed by the inbox on mount.
//
// Per tab, gone when the tab closes, never sent anywhere.
// ============================================================

const KEY = 'wacrm:inbox:open-target';

/** Ask the inbox to open `conversationId` the next time it mounts. */
export function setInboxOpenTarget(conversationId: string): void {
  try {
    window.sessionStorage.setItem(KEY, conversationId);
  } catch {
    // Storage blocked: the navigation still happens, just without the target.
  }
}

/** Read and consume the pending target, if any. */
export function takeInboxOpenTarget(): string | null {
  try {
    const id = window.sessionStorage.getItem(KEY);
    if (id) window.sessionStorage.removeItem(KEY);
    return id;
  } catch {
    return null;
  }
}
