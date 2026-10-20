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

vi.mock("@/hooks/use-auth", () => ({ useAuth: () => ({ accountRole: "agent" }) }));
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

async function renderWith(operations: unknown[]) {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ resolverState: "unica", resolverOperationId: null, resolverCandidateCount: operations.length, operations }), { status: 200 }),
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
