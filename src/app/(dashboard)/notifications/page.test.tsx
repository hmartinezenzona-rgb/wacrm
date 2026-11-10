// @vitest-environment jsdom
// The /notifications page: delete one notification with its X, delete all behind a confirmation. Deletes are
// optimistic; a failed delete shows a toast and reloads the list.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const push = vi.fn();
vi.mock("next/navigation", () => ({ useRouter: () => ({ push }) }));
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => ({ accountId: "acc-1", user: { id: "user-1" } }) }));
vi.mock("@/hooks/use-promo-pendiente", () => ({
  usePromoPendiente: () => ({ promo: null, checked: true, action: null, confirm: vi.fn(), discard: vi.fn() }),
}));
const toastError = vi.fn();
const toastSuccess = vi.fn();
vi.mock("sonner", () => ({ toast: { error: (m: string) => toastError(m), success: (m: string) => toastSuccess(m) } }));

let rows: Array<Record<string, unknown>> = [];
const deleteEq = vi.fn();
const updateCalls = vi.fn();
let realtimeHandler: ((payload: Record<string, unknown>) => void) | null = null;
let selectCount = 0;

const client = {
  from: () => ({
    select: () => {
      selectCount += 1;
      const chain = {
        eq: () => chain,
        order: () => chain,
        limit: () => Promise.resolve({ data: rows, error: null }),
      };
      return chain;
    },
    delete: () => ({ eq: (col: string, val: string) => deleteEq(col, val) }),
    update: () => {
      updateCalls();
      return { eq: () => ({ is: () => Promise.resolve({ error: null }) }) };
    },
  }),
  channel: () => {
    const ch = {
      on: (_e: string, _f: unknown, cb: (p: Record<string, unknown>) => void) => {
        realtimeHandler = cb;
        return ch;
      },
      subscribe: () => ch,
    };
    return ch;
  },
  removeChannel: vi.fn(),
};
vi.mock("@/lib/supabase/client", () => ({ createClient: () => client }));

const t = en.Notifications;
const note = (id: string, over: Record<string, unknown> = {}) => ({
  id, account_id: "acc-1", user_id: "user-1", type: "conversation_assigned", conversation_id: "conv-" + id,
  title: "Title " + id, body: null, read_at: null, created_at: new Date().toISOString(), ...over,
});

const mounted: Array<{ unmount: () => void }> = [];
afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((r) => r.unmount()));
  document.body.replaceChildren();
  deleteEq.mockReset(); updateCalls.mockReset(); push.mockReset(); toastError.mockReset(); toastSuccess.mockReset();
  realtimeHandler = null; selectCount = 0; rows = [];
});
beforeEach(() => { deleteEq.mockResolvedValue({ error: null }); });

async function mount() {
  const { default: NotificationsPage } = await import("./page");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<NotificationsPage />));
  mounted.push(root);
  return node;
}
const byLabel = (label: string) => Array.from(document.querySelectorAll("button")).filter((b) => b.getAttribute("aria-label") === label);
const byText = (text: string) => Array.from(document.querySelectorAll("button")).find((b) => b.textContent?.trim() === text);

describe("NotificationsPage digest", () => {
  it("shows the daily summary with its badge and the multi-line body", async () => {
    rows = [note("1", { type: "resumen_diario", conversation_id: null, title: "Resumen tecnico del dia: 3 avisos", body: "Mensajes que no llegaron: 2\n- uno\n- dos" })];
    const node = await mount();
    expect(node.textContent).toContain(t.digestBadge);
    expect(node.textContent).toContain("Resumen tecnico del dia: 3 avisos");
    expect(node.textContent).toContain("- dos");
  });

  it("does not show the digest badge on other notifications", async () => {
    rows = [note("1")];
    const node = await mount();
    expect(node.textContent).not.toContain(t.digestBadge);
  });
});

describe("NotificationsPage deleting", () => {
  it("shows an accessible X on every notification", async () => {
    rows = [note("1"), note("2")];
    await mount();
    expect(byLabel(t.deleteOne)).toHaveLength(2);
  });

  it("the X deletes that row optimistically without navigating or marking read", async () => {
    rows = [note("1"), note("2")];
    const node = await mount();
    await act(async () => byLabel(t.deleteOne)[0].click());
    expect(deleteEq).toHaveBeenCalledWith("id", "1");
    expect(node.textContent).not.toContain("Title 1");
    expect(node.textContent).toContain("Title 2");
    expect(push).not.toHaveBeenCalled();
    expect(updateCalls).not.toHaveBeenCalled();
  });

  it("a failed delete shows an error toast and reloads the list", async () => {
    rows = [note("1")];
    deleteEq.mockResolvedValue({ error: { message: "boom" } });
    const node = await mount();
    const before = selectCount;
    await act(async () => byLabel(t.deleteOne)[0].click());
    expect(toastError).toHaveBeenCalledWith(t.deleteError);
    expect(selectCount).toBe(before + 1);
    expect(node.textContent).toContain("Title 1");
  });

  it("delete all is disabled when the list is empty", async () => {
    rows = [];
    await mount();
    expect(byText(t.deleteAll)!.disabled).toBe(true);
  });

  it("delete all asks for confirmation and only then deletes the caller's rows", async () => {
    rows = [note("1"), note("2", { read_at: "2026-10-01T00:00:00Z" })];
    const node = await mount();
    await act(async () => byText(t.deleteAll)!.click());
    expect(document.body.textContent).toContain(t.deleteAllTitle);
    expect(document.body.textContent).toContain(t.deleteAllDescription);
    expect(deleteEq).not.toHaveBeenCalled();
    await act(async () => byText(t.deleteAllConfirm)!.click());
    expect(deleteEq).toHaveBeenCalledWith("user_id", "user-1");
    expect(node.textContent).not.toContain("Title 1");
    expect(node.textContent).not.toContain("Title 2");
    expect(toastSuccess).toHaveBeenCalledWith(t.deleteAllDone);
  });

  it("cancelling the confirmation deletes nothing", async () => {
    rows = [note("1")];
    const node = await mount();
    await act(async () => byText(t.deleteAll)!.click());
    await act(async () => byText(t.cancel)!.click());
    expect(deleteEq).not.toHaveBeenCalled();
    expect(node.textContent).toContain("Title 1");
  });

  it("a failed delete all shows an error toast and reloads", async () => {
    rows = [note("1")];
    deleteEq.mockResolvedValue({ error: { message: "boom" } });
    await mount();
    const before = selectCount;
    await act(async () => byText(t.deleteAll)!.click());
    await act(async () => byText(t.deleteAllConfirm)!.click());
    expect(toastError).toHaveBeenCalledWith(t.deleteAllError);
    expect(selectCount).toBe(before + 1);
  });

  it("a realtime DELETE still removes the row", async () => {
    rows = [note("1"), note("2")];
    const node = await mount();
    await act(async () => realtimeHandler!({ eventType: "DELETE", old: { id: "1" } }));
    expect(node.textContent).not.toContain("Title 1");
    expect(node.textContent).toContain("Title 2");
  });
});
