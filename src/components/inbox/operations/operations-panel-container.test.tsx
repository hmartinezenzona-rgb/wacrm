// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel. Covers the container's fetch + state
// machine: loads on conversationId, lists every open remesa (ninguna shows
// nothing / no fabrication, ambigua shows the banner + still lists every
// operation instead of picking one).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { ConversationOperationsRead } from "@/lib/remittance-operations/types";

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

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}

const OP1 = {
  id: "op-1",
  status: "deposit_verification" as const,
  serviceType: "remesa",
  sourceCurrency: "GYD",
  destinationCurrency: null,
  deliveryMethod: null,
  depositMethod: null,
  quotedSourceAmount: 10000,
  quotedDestinationAmount: null,
  adminLockedFields: {},
  createdAt: "2026-09-14T00:00:00Z",
  completedAt: null,
  beneficiaries: [
    {
      id: "ben-1",
      beneficiaryType: "cuban_card" as const,
      name: "Yaima Perez",
      cardNumberMasked: "9205****9412",
      phoneMasked: null,
      zelleAccount: null,
      deliveryMethod: null,
      amount: null,
      currency: null,
      position: 1,
    },
  ],
};

const OP2 = {
  ...OP1,
  id: "op-2",
  status: "awaiting_deposit" as const,
  beneficiaries: [],
};

async function renderContainer(conversationId: string | null) {
  const { OperationsPanelContainer } = await import("./operations-panel-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsPanelContainer conversationId={conversationId} />));
  return { node, root };
}

describe("OperationsPanelContainer", () => {
  it("renders nothing when there is no active conversation", async () => {
    vi.stubGlobal("fetch", vi.fn());
    const { node, root } = await renderContainer(null);
    await flush();

    expect(node.textContent).toBe("");
    await act(async () => root.unmount());
  });

  it("fetches the conversation's operations and lists every open remesa", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "unica",
      resolverOperationId: "op-1",
      resolverCandidateCount: 1,
      operations: [OP1],
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await renderContainer("conv-1");
    await flush();

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/remittance-operations?conversationId=conv-1",
      expect.objectContaining({ cache: "no-store" }),
    );
    expect(node.textContent).toContain("Yaima Perez");
    expect(node.textContent).toContain("9205****9412");
    await act(async () => root.unmount());
  });

  it("shows nothing and fabricates no operation when the resolver reports ninguna", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "ninguna",
      resolverOperationId: null,
      resolverCandidateCount: 0,
      operations: [],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

    const { node, root } = await renderContainer("conv-2");
    await flush();

    expect(node.textContent).toContain("No open remittance operations for this conversation.");
    expect(node.textContent).not.toContain("Yaima Perez");
    await act(async () => root.unmount());
  });

  it("shows the ambiguous banner AND still lists every open remesa (no auto-select)", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "ambigua",
      resolverOperationId: null,
      resolverCandidateCount: 2,
      operations: [OP1, OP2],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

    const { node, root } = await renderContainer("conv-3");
    await flush();

    expect(node.textContent).toContain("2 open operations for this conversation");
    // Both operations render — "no guessing" means not hiding data, not
    // picking a winner (spec: "List All Open Remesas Per Conversation").
    expect(node.querySelectorAll("article")).toHaveLength(2);
    await act(async () => root.unmount());
  });

  it("shows a load error when the fetch fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse({ error: "boom" }, 500)));

    const { node, root } = await renderContainer("conv-4");
    await flush();

    expect(node.textContent).toContain("Couldn't load remittance operations.");
    await act(async () => root.unmount());
  });
});
