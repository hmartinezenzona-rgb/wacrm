// @vitest-environment jsdom
// The unread badge must stay right after notifications are deleted. Supabase realtime does not apply RLS to DELETE
// events, so another user's delete reaches this client too: the hook recounts instead of decrementing from the payload.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let unread = 3;
let handler: ((payload: Record<string, unknown>) => void) | null = null;
const client = {
  from: () => ({ select: () => ({ is: () => Promise.resolve({ count: unread, error: null }) }) }),
  channel: () => {
    const ch = { on: (_e: string, _f: unknown, cb: (p: Record<string, unknown>) => void) => { handler = cb; return ch; }, subscribe: () => ch };
    return ch;
  },
  removeChannel: vi.fn(),
};
vi.mock("@/lib/supabase/client", () => ({ createClient: () => client }));

import { useUnreadNotifications } from "./use-unread-notifications";

function Probe() {
  return <span data-testid="n">{useUnreadNotifications()}</span>;
}

const mounted: Array<{ unmount: () => void }> = [];
afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((r) => r.unmount()));
  document.body.replaceChildren();
  handler = null;
});

async function mount() {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<Probe />));
  mounted.push(root);
  return node;
}

describe("useUnreadNotifications", () => {
  it("counts unread on mount", async () => {
    unread = 3;
    const node = await mount();
    expect(node.textContent).toBe("3");
  });

  it("recounts on a DELETE event, whoever's row it was", async () => {
    unread = 3;
    const node = await mount();
    unread = 0; // the caller deleted all of theirs
    await act(async () => handler!({ eventType: "DELETE", old: { id: "x", user_id: "me", read_at: null } }));
    expect(node.textContent).toBe("0");
    unread = 0;
    // another user's unread row is deleted: the recount keeps this user's number
    unread = 2;
    await act(async () => handler!({ eventType: "DELETE", old: { id: "y", user_id: "other", read_at: null } }));
    expect(node.textContent).toBe("2");
  });
});
