// @vitest-environment jsdom
// The "Edit split" action of an operation card (crm_editar_reparto): offered on an expanded remesa whose current
// recipients are all card rails (two or more), only when shared edits are allowed (open and editable, or closed for
// an owner/admin), and it opens the split edit form.

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
vi.mock("./split-edit-form", async (importOriginal) => {
  const original = await importOriginal<typeof import("./split-edit-form")>();
  return {
    ...original,
    SplitEditForm: ({ operationId, total, currency, beneficiaries, onDone }: { operationId: string; total: number | null; currency: string | null; beneficiaries: unknown[]; onDone: () => void }) => (
      <div data-testid="edit-split-stub" data-operation={operationId} data-total={String(total)} data-currency={currency} data-count={beneficiaries.length}>
        <button type="button" data-testid="edit-split-done" onClick={onDone}>
          done
        </button>
      </div>
    ),
  };
});

afterEach(() => {
  document.body.replaceChildren();
});

const label = en.Inbox.operationsPanel.editSplit.button;

const SHARE = { beneficiaryType: "cuban_card", name: null, cardNumber: "9205000000000001", phone: null, zelleAccount: null, deliveryMethod: null, amountOrigin: "manual", currency: "CUP", position: 0, address: null };

function operation(overrides: Partial<RemittanceOperationRead> = {}): RemittanceOperationRead {
  return {
    id: "op-1",
    status: "ready_to_transfer",
    serviceType: "remesa",
    sourceCurrency: "GYD",
    destinationCurrency: "CUP",
    deliveryMethod: null,
    depositMethod: null,
    quotedSourceAmount: 10000,
    quotedDestinationAmount: 150,
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
    beneficiaries: [
      { ...SHARE, id: "ben-1", amount: 100 },
      { ...SHARE, id: "ben-2", amount: 50 },
    ],
    ...overrides,
  } as unknown as RemittanceOperationRead;
}

async function render(op: RemittanceOperationRead, options: { canEdit?: boolean; role?: "agent" | "admin" | "owner"; expanded?: boolean } = {}) {
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
        role={options.role ?? "agent"}
        otherOpenOperations={[]}
        onChanged={onChanged}
        expanded={options.expanded ?? true}
        onToggle={vi.fn()}
        conversationId="conv-1"
      />,
    ),
  );
  return { node, root, onChanged };
}

const editButton = (node: Element) => node.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`);

describe("RemittanceOperationCard edit split", () => {
  it("is offered on an open remesa with two card shares and opens the form with the total", async () => {
    const { node, root } = await render(operation());

    await act(async () => editButton(node)!.click());

    const stub = node.querySelector('[data-testid="edit-split-stub"]')!;
    expect(stub.getAttribute("data-operation")).toBe("op-1");
    expect(stub.getAttribute("data-total")).toBe("150");
    expect(stub.getAttribute("data-currency")).toBe("CUP");
    expect(stub.getAttribute("data-count")).toBe("2");
    await act(async () => root.unmount());
  });

  it("closes the form and refetches when the edit is done", async () => {
    const { node, root, onChanged } = await render(operation());

    await act(async () => editButton(node)!.click());
    await act(async () => node.querySelector<HTMLButtonElement>('[data-testid="edit-split-done"]')!.click());

    expect(node.querySelector('[data-testid="edit-split-stub"]')).toBeNull();
    expect(onChanged).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("is offered on a closed operation to an owner/admin", async () => {
    const { node, root } = await render(operation({ status: "completed" }), { role: "admin" });

    expect(editButton(node)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("is hidden on a closed operation for an agent", async () => {
    const { node, root } = await render(operation({ status: "completed" }), { role: "agent" });

    expect(editButton(node)).toBeNull();
    await act(async () => root.unmount());
  });

  it.each([
    ["a viewer", operation(), { canEdit: false }],
    ["a collapsed card", operation(), { expanded: false }],
    ["a history row", operation({ isHistory: true }), {}],
    ["a single share", operation({ beneficiaries: [{ ...SHARE, id: "ben-1", amount: 150 }] as never }), {}],
    ["a non-card recipient", operation({ beneficiaries: [{ ...SHARE, id: "ben-1", amount: 100 }, { ...SHARE, id: "ben-2", amount: 50, beneficiaryType: "zelle" }] as never }), {}],
    ["a recharge", operation({ serviceType: "recarga" }), {}],
  ])("is hidden for %s", async (_label, op, options) => {
    const { node, root } = await render(op, options);

    expect(editButton(node)).toBeNull();
    await act(async () => root.unmount());
  });
});
