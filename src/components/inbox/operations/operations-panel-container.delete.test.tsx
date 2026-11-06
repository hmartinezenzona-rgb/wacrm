// @vitest-environment jsdom
// Spec: odd/tasks/deleted-operations-disappear.md (T2). A deleted operation leaves the panel at once (before the
// refetch) and a toast confirms it; the refetch then agrees with it.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { ConversationOperationsRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));
vi.mock("@/hooks/use-can", () => ({ useCan: () => true }));

const toastSuccess = vi.fn();
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: vi.fn() } }));

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ channel: () => ({ on() { return this; }, subscribe() { return this; } }), removeChannel: vi.fn() }),
}));

// The card is a stub that exposes its delete hook; the real wiring inside the card is covered by its own test.
vi.mock("./remittance-operation-card", () => ({
  RemittanceOperationCard: ({ operation, onDeleted }: { operation: { id: string }; onDeleted?: (id: string) => void }) => (
    <article data-testid={`card-${operation.id}`}>
      <button type="button" data-testid={`del-${operation.id}`} onClick={() => onDeleted?.(operation.id)} />
    </article>
  ),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  toastSuccess.mockReset();
});

function op(id: string): RemittanceOperationRead {
  return {
    id, status: "awaiting_deposit", serviceType: "remesa", sourceCurrency: "GYD", destinationCurrency: null,
    deliveryMethod: null, depositMethod: null, quotedSourceAmount: 1000, quotedDestinationAmount: null,
    quotedDestinationRate: null, quotedDestinationOrigin: null, adminLockedFields: {}, createdAt: "2026-09-14T00:00:00Z",
    completedAt: null, isHistory: false, beneficiariesComplete: true, deliveryMode: null, deliveredAt: null, beneficiaries: [],
  };
}

function payload(ids: string[]): ConversationOperationsRead {
  return { resolverState: "ambigua", resolverOperationId: null, resolverCandidateCount: ids.length, operations: ids.map(op) };
}

describe("OperationsPanelContainer deleting an operation", () => {
  it("removes the card at once, toasts, and a failing refetch keeps it removed", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(payload(["op-a", "op-b"]))))
      .mockRejectedValue(new Error("offline"));
    vi.stubGlobal("fetch", fetchMock);
    const { OperationsPanelContainer } = await import("./operations-panel-container");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<OperationsPanelContainer conversationId="conv-1" />));
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    expect(node.querySelector('[data-testid="card-op-a"]')).not.toBeNull();

    await act(async () => (node.querySelector('[data-testid="del-op-a"]') as HTMLButtonElement).click());

    expect(node.querySelector('[data-testid="card-op-a"]')).toBeNull();
    expect(node.querySelector('[data-testid="card-op-b"]')).not.toBeNull();
    expect(toastSuccess).toHaveBeenCalledWith(en.Inbox.operationsPanel.closing.deleted);
    await act(async () => root.unmount());
  });
});
