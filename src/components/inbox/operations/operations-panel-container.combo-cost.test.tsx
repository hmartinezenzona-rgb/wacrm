// @vitest-environment jsdom
// A completed combo sits in the panel's History, whose cards get no actions
// (role null). The owner/admin must still reach the combo cost field there:
// a combo closed without a cost is exactly the one the calculator is waiting on.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

const authState: { accountRole: string | null } = { accountRole: "owner" };
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => authState }));
vi.mock("@/hooks/use-can", () => ({ useCan: () => true }));
vi.mock("@/lib/remittance-operations/commands", () => ({ setComboCosto: vi.fn() }));
vi.mock("./deposit-review-container", () => ({ DepositReviewContainer: () => null }));
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => {
    const channel = { on: () => channel, subscribe: () => channel };
    return { channel: () => channel, removeChannel: () => {} };
  },
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.unstubAllGlobals();
});

const COMBO_HISTORY = {
  id: "op-combo-1",
  status: "completed",
  serviceType: "combo",
  sourceCurrency: "GYD",
  destinationCurrency: null,
  deliveryMethod: "combo",
  depositMethod: "mmg",
  quotedSourceAmount: 30000,
  quotedDestinationAmount: null,
  quotedDestinationRate: null,
  quotedDestinationOrigin: null,
  adminLockedFields: {},
  createdAt: "2026-10-01T00:00:00Z",
  completedAt: "2026-10-02T00:00:00Z",
  isHistory: true,
  beneficiariesComplete: true,
  deliveryMode: "closed_manually",
  deliveredAt: null,
  comboCostoGyd: null,
  beneficiaries: [],
};

async function renderWith(role: string | null) {
  authState.accountRole = role;
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({ resolverState: "ninguna", resolverOperationId: null, resolverCandidateCount: 0, operations: [COMBO_HISTORY] }),
        { status: 200 },
      ),
    ),
  );
  const { OperationsPanelContainer } = await import("./operations-panel-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsPanelContainer conversationId={`conv-${role}`} />));
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
  const click = (el: Element) => act(async () => void el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })));
  const toggle = Array.from(node.querySelectorAll<HTMLButtonElement>("button[aria-expanded]")).find((b) => !b.closest("article"))!;
  await click(toggle);
  await click(node.querySelector<HTMLButtonElement>("article button[aria-expanded]")!);
  return { node, root };
}

describe("OperationsPanelContainer combo cost on a completed combo", () => {
  it("an owner sees the cost field with the missing-cost hint in History", async () => {
    const { node, root } = await renderWith("owner");

    expect(node.textContent).toContain(en.Inbox.operationsPanel.comboCost.label);
    expect(node.textContent).toContain(en.Inbox.operationsPanel.comboCost.missing);
    await act(async () => root.unmount());
  });

  it("an agent does not", async () => {
    const { node, root } = await renderWith("agent");

    expect(node.textContent).not.toContain(en.Inbox.operationsPanel.comboCost.label);
    await act(async () => root.unmount());
  });
});
