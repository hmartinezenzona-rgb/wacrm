// @vitest-environment jsdom
// Slice: panel-26 (readiness). Covers the container's use of the
// hover/focus prefetch cache (panel-prefetch.ts): a fresh cache entry
// for `conversationId` must be used on the FIRST render (no loading
// skeleton at all — content shows before any network call even settles),
// with exactly one silent revalidation firing right after so a
// stale-by-seconds cache self-corrects without a loading flash. A cache
// miss must behave exactly like before this slice: blocked on the
// fetch, skeleton showing until it resolves (see
// operations-panel-container.test.tsx's own "holds the panel's shape
// while loading" test for that path's other, unchanged coverage).
//
// Both tests here use a manually-resolved fetch (never auto-resolving)
// so the assertions made BEFORE resolving it are the real discriminator:
// a hit must already show content while that fetch is still pending; a
// miss must not.

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

vi.mock("@/hooks/use-can", () => ({
  useCan: () => true,
}));

vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: vi.fn(),
  reasignarBeneficiario: vi.fn(),
}));

// Isolates this file from DepositReviewContainer's own fetch/receipts
// flow — same isolation operations-panel-container.test.tsx uses.
vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: () => null,
}));

function chainableChannel() {
  const chan = { on: () => chan, subscribe: () => chan };
  return chan;
}
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ channel: () => chainableChannel(), removeChannel: () => {} }),
}));

const readPrefetchedConversationOperations = vi.fn();
vi.mock("@/lib/remittance-operations/panel-prefetch", () => ({
  readPrefetchedConversationOperations: (...args: unknown[]) =>
    readPrefetchedConversationOperations(...args),
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
  readPrefetchedConversationOperations.mockReset();
});

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}

/** A fetch mock whose promise only resolves when the test calls
 *  `resolve()` — lets a test observe render state strictly BEFORE the
 *  network call settles, which is the actual behaviour under test. */
function pendingFetchMock() {
  let resolve!: (response: Response) => void;
  const mock = vi.fn(() => new Promise<Response>((res) => { resolve = res; }));
  return { mock, resolve: (body: unknown, status = 200) => resolve(jsonResponse(body, status)) };
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
  quotedDestinationRate: null,
  quotedDestinationOrigin: null,
  adminLockedFields: {},
  createdAt: "2026-09-14T00:00:00Z",
  completedAt: null,
  isHistory: false,
  beneficiariesComplete: true,
  deliveryMode: null,
  deliveredAt: null,
  beneficiaries: [
    {
      id: "ben-1",
      beneficiaryType: "cuban_card" as const,
      name: null,
      cardNumber: "9205123412349412",
      phone: null,
      zelleAccount: null,
      deliveryMethod: null,
      amount: null,
      amountOrigin: null,
      currency: null,
      position: 1,
      address: null,
      idPhotoWamid: null,
      idPhotoUrl: null,
    },
  ],
};

const DATA: ConversationOperationsRead = {
  resolverState: "unica",
  resolverOperationId: "op-1",
  resolverCandidateCount: 1,
  operations: [OP1],
};

async function renderContainer(conversationId: string | null) {
  const { OperationsPanelContainer } = await import("./operations-panel-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsPanelContainer conversationId={conversationId} />));
  return { node, root };
}

function isSkeletonShowing(node: Element) {
  return node.querySelector('[role="status"][aria-busy="true"]') !== null;
}

describe("OperationsPanelContainer — prefetch cache", () => {
  it("renders the cached operation immediately on a hit, before the revalidation request even resolves, and fires exactly one revalidation", async () => {
    readPrefetchedConversationOperations.mockReturnValue(DATA);
    const { mock: fetchMock, resolve } = pendingFetchMock();
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await renderContainer("conv-1");

    // The revalidation request is still pending at this point — a MISS
    // would still be showing the skeleton here (see the sibling test).
    // A hit must already show the cached card.
    expect(readPrefetchedConversationOperations).toHaveBeenCalledWith("conv-1");
    expect(isSkeletonShowing(node)).toBe(false);
    expect(node.textContent).toContain("9205 1234 1234 9412");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/remittance-operations?conversationId=conv-1",
      expect.objectContaining({ cache: "no-store" }),
    );

    resolve(DATA);
    await flush();

    // The one revalidation resolved silently — still no skeleton, still
    // exactly one network call total.
    expect(isSkeletonShowing(node)).toBe(false);
    expect(node.textContent).not.toContain(en.Inbox.operationsPanel.loading);
    expect(fetchMock).toHaveBeenCalledTimes(1);

    await act(async () => root.unmount());
  });

  it("behaves exactly as before on a miss: skeleton while the fetch is pending, then the loaded card", async () => {
    readPrefetchedConversationOperations.mockReturnValue(null);
    const { mock: fetchMock, resolve } = pendingFetchMock();
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await renderContainer("conv-2");

    expect(readPrefetchedConversationOperations).toHaveBeenCalledWith("conv-2");
    expect(isSkeletonShowing(node)).toBe(true);
    expect(node.textContent).not.toContain("9205 1234 1234 9412");

    resolve(DATA);
    await flush();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(node.textContent).toContain("9205 1234 1234 9412");
    expect(isSkeletonShowing(node)).toBe(false);

    await act(async () => root.unmount());
  });
});
