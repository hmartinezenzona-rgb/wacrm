// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel. Covers the container's fetch + state
// machine: loads on conversationId, lists every open remesa (ninguna shows
// nothing / no fabrication, ambigua shows the banner + still lists every
// operation instead of picking one), that a card reporting a change (via
// `onChanged`) makes the container refetch, and the accordion behavior:
// only one card is expanded at a time (owned here as `expandedId`),
// defaulting to the single operation when there's exactly one.

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

// canEdit gate: `useCan` composes with `useAuth`, which needs a provider
// this test doesn't set up. Mocked directly so the container's own
// canEdit-computation logic is what's under test, not the auth context.
vi.mock("@/hooks/use-can", () => ({
  useCan: () => true,
}));

const corregirBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: (...args: unknown[]) => corregirBeneficiario(...args),
  reasignarBeneficiario: vi.fn(),
}));

// Deposit review has its own fetch/network flow, covered by
// deposit-review-container.test.tsx — mocked here to a null-rendering
// stub so this file's accordion/resolver-state tests stay isolated from
// it (this container is rendered by the real, unmocked
// RemittanceOperationCard whenever a card is expanded).
vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: () => null,
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
      name: null,
      cardNumber: "9205123412349412",
      phone: null,
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

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function toggleButtons(node: Element) {
  return Array.from(node.querySelectorAll<HTMLButtonElement>("button[aria-expanded]"));
}

describe("OperationsPanelContainer", () => {
  it("renders nothing when there is no active conversation", async () => {
    vi.stubGlobal("fetch", vi.fn());
    const { node, root } = await renderContainer(null);
    await flush();

    expect(node.textContent).toBe("");
    await act(async () => root.unmount());
  });

  it("fetches the conversation's operations and lists every open remesa, auto-expanded when there's exactly one", async () => {
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
    expect(node.textContent).toContain("9205 1234 1234 9412");
    expect(toggleButtons(node)[0].getAttribute("aria-expanded")).toBe("true");
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
    expect(node.textContent).not.toContain("9205 1234 1234 9412");
    await act(async () => root.unmount());
  });

  it("shows the ambiguous banner AND still lists every open remesa, both collapsed (no auto-select)", async () => {
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
    const buttons = toggleButtons(node);
    expect(buttons).toHaveLength(2);
    expect(buttons.every((btn) => btn.getAttribute("aria-expanded") === "false")).toBe(true);
    await act(async () => root.unmount());
  });

  it("expands a card on click and collapses the previously expanded one", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "ambigua",
      resolverOperationId: null,
      resolverCandidateCount: 2,
      operations: [OP1, OP2],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

    const { node, root } = await renderContainer("conv-3b");
    await flush();

    let buttons = toggleButtons(node);
    await act(async () => {
      buttons[0].dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });
    buttons = toggleButtons(node);
    expect(buttons[0].getAttribute("aria-expanded")).toBe("true");
    expect(buttons[1].getAttribute("aria-expanded")).toBe("false");

    await act(async () => {
      buttons[1].dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });
    buttons = toggleButtons(node);
    expect(buttons[0].getAttribute("aria-expanded")).toBe("false");
    expect(buttons[1].getAttribute("aria-expanded")).toBe("true");
    await act(async () => root.unmount());
  });

  it("shows a load error when the fetch fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse({ error: "boom" }, 500)));

    const { node, root } = await renderContainer("conv-4");
    await flush();

    expect(node.textContent).toContain("Couldn't load remittance operations.");
    await act(async () => root.unmount());
  });

  it("refetches when a card reports a change via onChanged", async () => {
    // The shared name field only renders for a "zelle" beneficiary
    // (cuban_card beneficiaries have no name) — this test needs
    // `#beneficiary-name`, so it uses a zelle variant of OP1's
    // beneficiary while every other test keeps OP1's cuban_card shape.
    const zelleBeneficiary = {
      id: "ben-1",
      beneficiaryType: "zelle" as const,
      name: "Yaima Perez",
      cardNumber: null,
      phone: null,
      zelleAccount: "yaima@example.invalid",
      deliveryMethod: null,
      amount: null,
      currency: null,
      position: 1,
    };
    const data: ConversationOperationsRead = {
      resolverState: "unica",
      resolverOperationId: "op-1",
      resolverCandidateCount: 1,
      operations: [{ ...OP1, beneficiaries: [zelleBeneficiary] }],
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);
    corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });

    const { node, root } = await renderContainer("conv-5");
    await flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);

    const editButton = Array.from(node.querySelectorAll("button")).find(
      (btn) => btn.getAttribute("aria-label") === en.Inbox.operationsPanel.editBeneficiary,
    ) as HTMLButtonElement;
    await act(async () => {
      editButton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    const nameInput = node.querySelector<HTMLInputElement>("#beneficiary-name")!;
    await act(async () => setValue(nameInput, "Yaima Perez Updated"));

    const form = node.querySelector("form")!;
    await act(async () => {
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    });
    await flush();

    expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: "Yaima Perez Updated" });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await act(async () => root.unmount());
  });
});
