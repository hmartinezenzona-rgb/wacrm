// @vitest-environment jsdom
// The "Split deposit" action of an operation card (crm_repartir_envio): offered on an expanded, editable, open card;
// opens the split editor with the group's members (the operation alone when none are given); a finished split closes
// the editor and asks the panel to refetch.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

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

vi.mock("@/lib/remittance-operations/commands", () => ({ corregirBeneficiario: vi.fn() }));
vi.mock("./deposit-review-container", () => ({ DepositReviewContainer: () => null }));
vi.mock("./operation-correction-form", () => ({ OperationCorrectionForm: () => null }));
vi.mock("./split-deposit-form", () => ({
  SplitDepositForm: ({ operationId, members, onDone }: { operationId: string; members: RemittanceOperationRead[]; onDone: () => void }) => (
    <div data-testid="split-stub" data-operation={operationId} data-members={members.map((m) => m.id).join(",")}>
      <button type="button" data-testid="split-done" onClick={onDone}>
        done
      </button>
    </div>
  ),
}));

afterEach(() => {
  document.body.replaceChildren();
});

const label = en.Inbox.operationsPanel.splitDeposit.button;

function operation(overrides: Partial<RemittanceOperationRead> = {}): RemittanceOperationRead {
  return {
    id: "op-1",
    status: "deposit_verification",
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
    createdAt: "2026-10-20T00:00:00Z",
    completedAt: null,
    isHistory: false,
    beneficiariesComplete: true,
    deliveryMode: null,
    deliveredAt: null,
    mixedGroupId: null,
    beneficiaries: [],
    ...overrides,
  } as RemittanceOperationRead;
}

async function render(op: RemittanceOperationRead, options: { canEdit?: boolean; mixedMembers?: RemittanceOperationRead[]; expanded?: boolean } = {}) {
  const { RemittanceOperationCard } = await import("./remittance-operation-card");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onChanged = vi.fn();
  await act(async () =>
    root.render(
      <RemittanceOperationCard
        operation={op}
        canEdit={options.canEdit ?? true}
        role="agent"
        otherOpenOperations={[]}
        onChanged={onChanged}
        expanded={options.expanded ?? true}
        onToggle={vi.fn()}
        conversationId="conv-1"
        mixedMembers={options.mixedMembers}
      />,
    ),
  );
  return { node, root, onChanged };
}

const splitButton = (node: Element) => node.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`);

describe("RemittanceOperationCard split deposit", () => {
  it("opens the editor with the operation alone when it is not grouped", async () => {
    const { node, root } = await render(operation());

    await act(async () => splitButton(node)!.click());

    const stub = node.querySelector('[data-testid="split-stub"]')!;
    expect(stub.getAttribute("data-operation")).toBe("op-1");
    expect(stub.getAttribute("data-members")).toBe("op-1");
    await act(async () => root.unmount());
  });

  it("opens the editor with the group's members, and closes it and refetches when the split is done", async () => {
    const members = [operation({ id: "op-1", mixedGroupId: "op-1" }), operation({ id: "op-2", mixedGroupId: "op-1" })];
    const { node, root, onChanged } = await render(members[1]!, { mixedMembers: members });

    await act(async () => splitButton(node)!.click());
    expect(node.querySelector('[data-testid="split-stub"]')!.getAttribute("data-members")).toBe("op-1,op-2");

    await act(async () => node.querySelector<HTMLButtonElement>('[data-testid="split-done"]')!.click());

    expect(node.querySelector('[data-testid="split-stub"]')).toBeNull();
    expect(onChanged).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("toggles the editor closed on a second click", async () => {
    const { node, root } = await render(operation());

    await act(async () => splitButton(node)!.click());
    await act(async () => splitButton(node)!.click());

    expect(node.querySelector('[data-testid="split-stub"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("is not offered to a viewer, on a finished operation, in history or on a collapsed card", async () => {
    for (const [op, options] of [
      [operation(), { canEdit: false }],
      [operation({ status: "completed" }), {}],
      [operation({ isHistory: true }), {}],
      [operation(), { expanded: false }],
    ] as const) {
      const { node, root } = await render(op, options);
      expect(splitButton(node)).toBeNull();
      await act(async () => root.unmount());
      document.body.replaceChildren();
    }
  });
});
