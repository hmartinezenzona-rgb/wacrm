// @vitest-environment jsdom
// A mixed send (migration 253) renders its open operations together under one header with the deposit total and each
// share; an ungrouped operation renders exactly as before, with no header.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { formatNumber } from "@/lib/format-number";

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

const auth = vi.hoisted(() => ({ role: "agent" as string }));
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => ({ accountRole: auth.role }) }));
vi.mock("@/hooks/use-can", () => ({ useCan: () => true }));
vi.mock("@/lib/remittance-operations/commands", () => ({}));
vi.mock("./deposit-review-container", () => ({ DepositReviewContainer: () => null }));
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => {
    const channel = { on: () => channel, subscribe: () => channel };
    return { channel: () => channel, removeChannel: () => {} };
  },
}));

afterEach(() => {
  auth.role = "agent";
  document.body.replaceChildren();
  vi.unstubAllGlobals();
});

const t = en.Inbox.operationsPanel.mixedSend;

function op(id: string, amount: number, extra: Record<string, unknown> = {}) {
  return {
    id,
    status: "ready_to_transfer",
    serviceType: "remesa",
    sourceCurrency: "GYD",
    destinationCurrency: null,
    deliveryMethod: "clasica",
    depositMethod: "mmg",
    quotedSourceAmount: amount,
    quotedDestinationAmount: null,
    quotedDestinationRate: null,
    quotedDestinationOrigin: null,
    adminLockedFields: {},
    createdAt: "2026-10-20T00:00:00Z",
    completedAt: null,
    isHistory: false,
    beneficiariesComplete: true,
    deliveryMode: null,
    deliveredAt: null,
    mixedGroupId: null,
    beneficiaries: [],
    ...extra,
  };
}

async function renderWith(operations: unknown[], receiptsByOperationId?: Record<string, unknown>) {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ resolverState: "unica", resolverOperationId: null, resolverCandidateCount: operations.length, operations, receiptsByOperationId }), { status: 200 }),
    ),
  );
  const { OperationsPanelContainer } = await import("./operations-panel-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsPanelContainer conversationId={`conv-${Math.random()}`} />));
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
  return { node, root };
}

const deposit = (transId: string) => ({ transId, amount: 24400, currency: "GYD", receivedAt: null, consumedAt: null });
const receiptsOf = (id: string, ...consumed: ReturnType<typeof deposit>[]) => ({
  operationId: id,
  status: "ready_to_transfer",
  dealId: null,
  canVerify: false,
  objetivo: null,
  depositado: null,
  saldo: null,
  moneda: "GYD",
  receipts: [],
  consumedDeposits: consumed,
});
const groupParts = () => [
  op("a", 18200, { mixedGroupId: "a" }),
  op("b", 6200, { mixedGroupId: "a", serviceType: "recarga", deliveryMethod: null }),
];

/** The panel is an accordion (one card open at a time): open each card in turn and tally the buttons by label. */
async function tallyButtons(node: HTMLElement) {
  const tally = new Map<string, number>();
  const count = (label: string | null) => tally.set(label ?? "", (tally.get(label ?? "") ?? 0) + 1);
  const headers = Array.from(node.querySelectorAll("article button[aria-expanded]")) as HTMLButtonElement[];
  for (const header of headers) {
    await act(async () => header.click());
    const article = header.closest("article")!;
    Array.from(article.querySelectorAll("button")).forEach((button) => count(button.textContent));
  }
  // The group's own buttons sit at the end of the block, outside the cards.
  Array.from(node.querySelectorAll("section > button")).forEach((button) => count(button.textContent));
  return tally;
}

describe("OperationsPanelContainer mixed send completion", () => {
  const complete = en.Inbox.operationsPanel.mixedSend.complete;
  const perPart = en.Inbox.operationsPanel.completeTransfer.button;

  it("shows one Completar envio and no per-part Completar when one deposit pays the whole group", async () => {
    const { node, root } = await renderWith(groupParts(), {
      a: receiptsOf("a", deposit("T-0001")),
      b: receiptsOf("b"),
    });
    const tally = await tallyButtons(node);

    expect(tally.get(complete)).toBe(1);
    expect(tally.get(perPart) ?? 0).toBe(0);
    expect(node.querySelector("section")!.textContent).toContain("0001");
    await act(async () => root.unmount());
  });

  it("shows the status once, in the block header, and not on each member card", async () => {
    const { node, root } = await renderWith(groupParts(), { a: receiptsOf("a", deposit("T-0001")), b: receiptsOf("b") });
    const label = en.Inbox.operationsPanel.status.ready_to_transfer;

    expect(node.querySelector("section > header")!.textContent).toContain(label);
    expect(node.querySelectorAll("article")).toHaveLength(2);
    expect(node.querySelector("article")!.textContent).not.toContain(label);
    expect(node.querySelector("section > header")!.textContent).toContain(
      en.Inbox.operationsPanel.mixedSend.verifiedDeposit.replace("{transId}", "0001"),
    );
    await act(async () => root.unmount());
  });

  it("puts Completar envio after the member cards and opens the completion inline, not in a dialog", async () => {
    const { node, root } = await renderWith(groupParts(), {
      a: receiptsOf("a", deposit("T-0001")),
      b: receiptsOf("b"),
    });
    const open = Array.from(node.querySelectorAll("section > button")).find((b) => b.textContent === complete) as HTMLButtonElement;
    expect(node.querySelector("article:last-of-type")!.compareDocumentPosition(open) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    await act(async () => open.click());

    expect(document.body.querySelector('[role="dialog"]')).toBeNull();
    const block = node.querySelector("section")!;
    expect(block.textContent).toContain(en.Inbox.operationsPanel.completeMixedSend.title);
    expect(block.querySelectorAll("section")).toHaveLength(2);
    expect(block.querySelectorAll("article")).toHaveLength(0);
    expect(Array.from(block.querySelectorAll(":scope > button"))).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("offers one Cerrar manualmente at the end of the block to an owner, in place of the per-card ones", async () => {
    auth.role = "owner";
    const parts = [op("a", 18200, { mixedGroupId: "a" }), op("b", 6200, { mixedGroupId: "a", serviceType: "recarga", deliveryMethod: "recarga" })];
    const { node, root } = await renderWith(parts, { a: receiptsOf("a", deposit("T-0001")), b: receiptsOf("b") });
    const tally = await tallyButtons(node);

    expect(tally.get(en.Inbox.operationsPanel.closing.closeButton)).toBe(1);
    await act(async () => root.unmount());
  });

  it("keeps each card's own Cerrar manualmente when a member needs its service picked first", async () => {
    auth.role = "owner";
    const { node, root } = await renderWith(groupParts(), { a: receiptsOf("a", deposit("T-0001")), b: receiptsOf("b") });
    const tally = await tallyButtons(node);

    expect(tally.get(en.Inbox.operationsPanel.closing.closeButton)).toBe(2);
    await act(async () => root.unmount());
  });

  it("offers no group Cerrar manualmente to an agent", async () => {
    const { node, root } = await renderWith(groupParts(), { a: receiptsOf("a", deposit("T-0001")), b: receiptsOf("b") });
    const tally = await tallyButtons(node);

    expect(tally.get(en.Inbox.operationsPanel.closing.closeButton) ?? 0).toBe(0);
    await act(async () => root.unmount());
  });

  it("keeps the per-part Completar with two deposits", async () => {
    const { node, root } = await renderWith(groupParts(), {
      a: receiptsOf("a", deposit("T-0001")),
      b: receiptsOf("b", deposit("T-0002")),
    });
    const tally = await tallyButtons(node);

    expect(tally.get(complete) ?? 0).toBe(0);
    expect(tally.get(perPart)).toBe(2);
    await act(async () => root.unmount());
  });

  it("keeps the per-part Completar when a member is not ready", async () => {
    const parts = groupParts();
    parts[1] = op("b", 6200, { mixedGroupId: "a", status: "deposit_verification" });
    const { node, root } = await renderWith(parts, { a: receiptsOf("a", deposit("T-0001")), b: receiptsOf("b") });
    const tally = await tallyButtons(node);

    expect(tally.get(complete) ?? 0).toBe(0);
    expect(tally.get(perPart)).toBe(1);
    await act(async () => root.unmount());
  });
});

describe("OperationsPanelContainer mixed send", () => {
  it("puts the open members of a group under one header with the total and every share, next to an ungrouped card", async () => {
    const { node, root } = await renderWith([
      op("a", 18200, { mixedGroupId: "a" }),
      op("lone", 700),
      op("b", 6200, { mixedGroupId: "a", serviceType: "recarga", deliveryMethod: null }),
    ]);

    const sections = node.querySelectorAll("section");
    expect(sections).toHaveLength(1);
    expect(sections[0]!.textContent).toContain(t.title);
    expect(sections[0]!.textContent).toContain(t.total.replace("{amount}", formatNumber(24400)));
    expect(sections[0]!.querySelectorAll("article")).toHaveLength(2);
    expect(node.querySelectorAll("article")).toHaveLength(3);
    await act(async () => root.unmount());
  });

  it("renders an ungrouped operation without a header", async () => {
    const { node, root } = await renderWith([op("lone", 700)]);

    expect(node.querySelectorAll("section")).toHaveLength(0);
    expect(node.textContent).not.toContain(t.title);
    expect(node.querySelectorAll("article")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  describe("history", () => {
    const done = (id: string, amount: number, extra: Record<string, unknown> = {}) =>
      op(id, amount, { status: "completed", isHistory: true, completedAt: "2026-10-20T01:00:00Z", ...extra });

    async function openHistory(node: HTMLElement) {
      const toggle = Array.from(node.querySelectorAll("button")).find((button) =>
        button.textContent?.startsWith(en.Inbox.operationsPanel.historyTitle),
      ) as HTMLButtonElement;
      await act(async () => toggle.click());
    }

    it("shows the completed members of a group together under one header inside Historial", async () => {
      const { node, root } = await renderWith([
        done("a", 18200, { mixedGroupId: "a" }),
        done("b", 6200, { mixedGroupId: "a", serviceType: "recarga", deliveryMethod: null }),
      ]);
      await openHistory(node);

      const sections = node.querySelectorAll("section");
      expect(sections).toHaveLength(1);
      expect(sections[0]!.textContent).toContain(t.title);
      expect(sections[0]!.textContent).toContain(t.total.replace("{amount}", formatNumber(24400)));
      expect(sections[0]!.querySelectorAll("article")).toHaveLength(2);
      await act(async () => root.unmount());
    });

    it("leaves ungrouped history operations and a lone completed member as plain cards", async () => {
      const { node, root } = await renderWith([
        done("lone", 700),
        done("a", 18200, { mixedGroupId: "a" }),
        op("open", 6200, { mixedGroupId: "a" }),
      ]);
      await openHistory(node);

      // The only header is the open block of the group; the completed member stays a plain history card.
      const sections = node.querySelectorAll("section");
      expect(sections).toHaveLength(1);
      expect(sections[0]!.querySelectorAll("article")).toHaveLength(1);
      expect(node.querySelectorAll("article")).toHaveLength(3);
      await act(async () => root.unmount());
    });

    it("never splits a history group across the show-more limit", async () => {
      const singles = ["s1", "s2", "s3", "s4"].map((id) => done(id, 100));
      const { node, root } = await renderWith([
        ...singles,
        done("a", 18200, { mixedGroupId: "a" }),
        done("b", 6200, { mixedGroupId: "a" }),
        done("s5", 100),
      ]);
      await openHistory(node);

      expect(node.querySelectorAll("section")).toHaveLength(1);
      expect(node.querySelectorAll("section article")).toHaveLength(2);
      expect(node.querySelectorAll("article")).toHaveLength(6);
      await act(async () => root.unmount());
    });
  });
});
