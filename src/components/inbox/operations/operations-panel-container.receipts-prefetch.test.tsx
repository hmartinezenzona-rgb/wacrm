// @vitest-environment jsdom
// Slice: panel-26 (readiness). Integration test for the collapsed
// waterfall: GET /api/remittance-operations now composes
// `receiptsByOperationId` alongside the operations list (route.test.ts
// covers the route itself), and the deposit block must paint from that
// prefetch in the SAME pass as the rest of the card — no second round
// trip through `GET .../{operationId}/receipts`.
//
// Unlike operations-panel-container.test.tsx (which mocks
// DepositReviewContainer away to isolate accordion/resolver-state
// behavior), this file renders the real component tree —
// OperationsPanelContainer -> RemittanceOperationCard ->
// DepositReviewContainer — end to end, so the prop actually has to flow
// through all three layers for these tests to pass.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { ConversationOperationsRead, OperationReceiptsRead } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

// canEdit gate: same isolation as operations-panel-container.test.tsx —
// `useCan` composes with `useAuth`, which needs a provider this test
// doesn't set up.
vi.mock("@/hooks/use-can", () => ({
  useCan: () => true,
}));

const fetchOperationReceipts = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: vi.fn(),
  reasignarBeneficiario: vi.fn(),
  fetchOperationReceipts: (...args: unknown[]) => fetchOperationReceipts(...args),
  verifyDeposit: vi.fn(),
  forceVerifyDeposit: vi.fn(),
  deliverOperation: vi.fn(),
}));

function chainableChannel() {
  const chan = {
    on: () => chan,
    subscribe: () => chan,
  };
  return chan;
}
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ channel: () => chainableChannel(), removeChannel: () => {} }),
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
    },
  ],
};

// canVerify: false + a VERIFIED_STATUSES status renders the "Deposit
// verified" branch of DepositReviewSection — the exact content that used
// to be the LAST thing to paint (deposit-review-container.tsx, panel-26).
const RECEIPTS_OP1: OperationReceiptsRead = {
  operationId: "op-1",
  status: "ready_to_transfer",
  dealId: "deal-1",
  canVerify: false,
  objetivo: 25000,
  depositado: 25000,
  saldo: 0,
  moneda: "GYD",
  receipts: [
    {
      compId: "comp-1",
      messageId: "msg-1",
      mediaUrl: null,
      receivedAt: "2026-09-10T00:00:00Z",
      declaredAmount: 25000,
      declaredCurrency: "GYD",
      declaredRef: "10412345678901",
      matchedDeposit: {
        transId: "10412345678901",
        amount: 25000,
        currency: "GYD",
        receivedAt: "2026-09-10T00:00:00Z",
        consumedAt: "2026-09-10T00:00:00Z",
      },
    },
  ],
  consumedDeposits: [],
};

async function renderContainer(conversationId: string | null) {
  const { OperationsPanelContainer } = await import("./operations-panel-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsPanelContainer conversationId={conversationId} />));
  return { node, root };
}

describe("OperationsPanelContainer — receipts prefetch reaches the card", () => {
  it("renders the deposit content from the prefetch after ONE fetch, with no second (receipts) fetch needed", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "unica",
      resolverOperationId: "op-1",
      resolverCandidateCount: 1,
      operations: [OP1],
      receiptsByOperationId: { "op-1": RECEIPTS_OP1 },
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await renderContainer("conv-1");
    await flush();

    // Single open operation auto-expands, so DepositReviewContainer mounts
    // without any click.
    expect(node.textContent).toContain(en.Inbox.operationsPanel.depositReview.verified);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchOperationReceipts).not.toHaveBeenCalled();

    await act(async () => root.unmount());
  });

  it("falls back to fetching its own receipts when the prefetch omits this operation (route's receipts RPC failed, or map has no entry)", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "unica",
      resolverOperationId: "op-1",
      resolverCandidateCount: 1,
      operations: [OP1],
      receiptsByOperationId: {},
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: RECEIPTS_OP1 });

    const { node, root } = await renderContainer("conv-2");
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledWith("op-1");
    expect(node.textContent).toContain(en.Inbox.operationsPanel.depositReview.verified);

    await act(async () => root.unmount());
  });
});
