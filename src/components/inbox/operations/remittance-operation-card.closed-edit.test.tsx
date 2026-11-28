// @vitest-environment jsdom
// Spec: panel-fully-editable T5. A closed operation (raw status completed or
// cancelled) may still be corrected by an owner/admin (migration 383): the
// card exposes only the operation correction (amounts, destination currency,
// rails and service), the recipient edit/add/remove and change-service
// affordances, plus one audited banner. Open-only controls (status change,
// complete/deliver, verify/force-verify, close-manual, delete, split,
// reassign) stay hidden. Agents and viewers keep the card read-only.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceBeneficiaryRead, RemittanceOperationRead, RemittanceOperationStatus } from "@/lib/remittance-operations/types";

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

vi.mock("@/lib/remittance-operations/commands", () => ({
  fetchCalculatorRates: vi.fn().mockResolvedValue(null),
  corregirOperacion: vi.fn(),
  corregirBeneficiario: vi.fn(),
  reasignarBeneficiario: vi.fn(),
  quitarBeneficiario: vi.fn(),
  cambiarEstado: vi.fn(),
  agregarBeneficiario: vi.fn(),
  cambiarServicio: vi.fn(),
}));

vi.mock("./operation-correction-form", () => ({
  OperationCorrectionForm: ({ operation }: { operation: RemittanceOperationRead }) => (
    <div data-testid="correction-stub" data-operation={operation.id} />
  ),
}));

vi.mock("./beneficiary-add-control", () => ({
  BeneficiaryAddControl: ({ operationId }: { operationId: string }) => (
    <div data-testid="add-beneficiary-stub" data-operation={operationId} />
  ),
}));

vi.mock("./beneficiary-remove-control", () => ({
  BeneficiaryRemoveControl: ({ beneficiaryId }: { beneficiaryId: string }) => (
    <div data-testid="remove-beneficiary-stub" data-beneficiary={beneficiaryId} />
  ),
}));

vi.mock("./beneficiary-reassign-control", () => ({
  BeneficiaryReassignControl: ({ beneficiaryId }: { beneficiaryId: string }) => (
    <div data-testid="reassign-beneficiary-stub" data-beneficiary={beneficiaryId} />
  ),
}));

vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: ({
    canEdit,
    role,
    onAddAmount,
  }: {
    canEdit: boolean;
    role: string | null;
    onAddAmount?: () => void;
  }) => (
    <div
      data-testid="deposit-review-stub"
      data-can-edit={String(canEdit)}
      data-role={role ?? ""}
      data-has-add-amount={String(Boolean(onAddAmount))}
    />
  ),
}));

vi.mock("./operation-closing-control", () => ({
  OperationClosingControl: ({ kind }: { kind: string }) => <div data-testid="closing-stub" data-kind={kind} />,
}));

vi.mock("./complete-transfer-container", () => ({
  CompleteTransferContainer: () => <div data-testid="complete-transfer-stub" />,
}));

vi.mock("./combo-cost-field", () => ({
  ComboCostField: () => null,
}));

vi.mock("./cup-plan-block", () => ({
  CupPlanBlock: () => <div data-testid="cup-plan-stub" />,
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.clearAllMocks();
});

function operation(overrides: Partial<RemittanceOperationRead> = {}): RemittanceOperationRead {
  return {
    id: "op-1",
    status: "deposit_verification",
    serviceType: "remesa",
    sourceCurrency: "GYD",
    destinationCurrency: "USD",
    deliveryMethod: "zelle",
    depositMethod: null,
    quotedSourceAmount: 10000,
    quotedDestinationAmount: 100,
    quotedDestinationRate: null,
    quotedDestinationOrigin: null,
    adminLockedFields: {},
    createdAt: "2026-09-14T00:00:00Z",
    completedAt: null,
    isHistory: false,
    beneficiariesComplete: true,
    deliveryMode: null,
    deliveredAt: null,
    comboCostoGyd: null,
    beneficiaries: [],
    ...overrides,
  };
}

function beneficiary(overrides: Partial<RemittanceBeneficiaryRead> = {}): RemittanceBeneficiaryRead {
  return {
    id: "b-1",
    beneficiaryType: "zelle",
    name: "Persona Uno",
    cardNumber: null,
    phone: null,
    zelleAccount: "uno@example.invalid",
    deliveryMethod: null,
    amount: 30,
    amountOrigin: null,
    currency: "USD",
    position: 1,
    address: null,
    reference: null,
    contactPhone: null,
    idPhotoWamid: null,
    idPhotoUrl: null,
    ...overrides,
  };
}

const twoRecipients = () => [
  beneficiary({ id: "b-1" }),
  beneficiary({ id: "b-2", name: "Persona Dos", zelleAccount: "dos@example.invalid", amount: 70, position: 2 }),
];

interface RenderOptions {
  canEdit?: boolean;
  role?: "owner" | "admin" | "agent" | "viewer" | null;
  otherOpenOperations?: { id: string; label: string }[];
  expanded?: boolean;
}

async function render(op: RemittanceOperationRead, options: RenderOptions = {}) {
  const { RemittanceOperationCard } = await import("./remittance-operation-card");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <RemittanceOperationCard
        operation={op}
        canEdit={options.canEdit ?? true}
        role={options.role ?? "agent"}
        otherOpenOperations={options.otherOpenOperations ?? []}
        onChanged={vi.fn()}
        expanded={options.expanded ?? true}
        onToggle={vi.fn()}
        conversationId="conv-1"
      />,
    ),
  );
  return { node, root };
}

const P = en.Inbox.operationsPanel;
const button = (node: Element, label: string) => node.querySelector(`button[aria-label="${label}"]`);
const click = (el: Element) => act(async () => el.dispatchEvent(new MouseEvent("click", { bubbles: true })));

const closed = (status: "completed" | "cancelled", overrides: Partial<RemittanceOperationRead> = {}) =>
  operation({
    status: status as RemittanceOperationStatus,
    isHistory: true,
    deliveryMode: "proof_sent",
    completedAt: "2026-10-01T10:00:00Z",
    deliveredAt: "2026-10-01T10:00:00Z",
    beneficiaries: twoRecipients(),
    ...overrides,
  });

const closedEditAffordances = (node: Element) => ({
  operation: button(node, P.editOperation),
  edit: node.querySelectorAll(`button[aria-label="${P.editBeneficiary}"]`),
  add: button(node, P.addBeneficiary),
  remove: node.querySelectorAll(`button[aria-label="${P.removeBeneficiary}"]`),
});

const openOnlyAffordances = (node: Element) => ({
  status: button(node, P.changeStatus),
  split: button(node, P.splitDeposit.button),
  delete: button(node, P.closing.deleteButton),
  complete: node.textContent?.includes(P.completeTransfer.button) ?? false,
});

describe.each(["completed", "cancelled"] as const)("a %s operation, owner", (status) => {
  it("offers only the shared edits: operation correction, recipient edit/add/remove, change service", async () => {
    const { node, root } = await render(closed(status), { role: "owner" });
    const affordances = closedEditAffordances(node);

    expect(affordances.operation).not.toBeNull();
    expect(affordances.edit).toHaveLength(2);
    expect(affordances.add).not.toBeNull();
    expect(affordances.remove).toHaveLength(2);
    expect(button(node, P.moveBeneficiary)).toBeNull();
    await act(async () => root.unmount());
  });

  it("hides every open-only control", async () => {
    const { node, root } = await render(closed(status), { role: "owner" });
    const open = openOnlyAffordances(node);

    expect(open.status).toBeNull();
    expect(open.split).toBeNull();
    expect(open.delete).toBeNull();
    expect(open.complete).toBe(false);
    expect(node.querySelector('[data-testid="complete-transfer-stub"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("keeps the deposit block read-only: no verify, no force-verify escalation", async () => {
    const { node, root } = await render(closed(status), { role: "owner" });
    const deposit = node.querySelector('[data-testid="deposit-review-stub"]')!;

    expect(deposit.getAttribute("data-can-edit")).toBe("false");
    expect(deposit.getAttribute("data-role")).toBe("");
    await act(async () => root.unmount());
  });

  it("shows the audited, no-recalculation banner", async () => {
    const { node, root } = await render(closed(status), { role: "owner" });

    expect(node.textContent).toContain(P.closedEdit.title);
    expect(node.textContent).toContain(P.closedEdit.body);
    await act(async () => root.unmount());
  });
});

describe("closed operation shared edit flows", () => {
  it("the correction pencil opens the operation-correction form (amounts, destination, rails and service)", async () => {
    const { node, root } = await render(closed("completed"), { role: "admin" });

    await click(button(node, P.editOperation)!);

    expect(node.querySelector('[data-testid="correction-stub"]')?.getAttribute("data-operation")).toBe("op-1");
    await act(async () => root.unmount());
  });

  it("the recipient pencil opens its inline fields", async () => {
    const { node, root } = await render(closed("completed"), { role: "owner" });

    await click(node.querySelectorAll(`button[aria-label="${P.editBeneficiary}"]`)[0]!);

    expect(node.querySelector("#inline-name-b-1")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("the add recipient button opens the add control", async () => {
    const { node, root } = await render(closed("completed"), { role: "owner" });

    await click(button(node, P.addBeneficiary)!);

    expect(node.querySelector('[data-testid="add-beneficiary-stub"]')?.getAttribute("data-operation")).toBe("op-1");
    await act(async () => root.unmount());
  });

  it("the remove recipient button opens the remove control", async () => {
    const { node, root } = await render(closed("completed"), { role: "owner" });

    await click(node.querySelectorAll(`button[aria-label="${P.removeBeneficiary}"]`)[0]!);

    expect(node.querySelector('[data-testid="remove-beneficiary-stub"]')?.getAttribute("data-beneficiary")).toBe("b-1");
    await act(async () => root.unmount());
  });
});

describe.each(["agent", "viewer", null] as const)("a closed operation, role %s", (role) => {
  it("stays fully read-only: no shared edits and no banner", async () => {
    const { node, root } = await render(closed("completed"), { role });
    const affordances = closedEditAffordances(node);

    expect(affordances.operation).toBeNull();
    expect(affordances.edit).toHaveLength(0);
    expect(affordances.add).toBeNull();
    expect(affordances.remove).toHaveLength(0);
    expect(node.textContent).not.toContain(P.closedEdit.title);
    expect(node.textContent).not.toContain(P.closedEdit.body);
    await act(async () => root.unmount());
  });

  it("still refuses the open-only controls", async () => {
    const { node, root } = await render(closed("completed"), { role });
    const open = openOnlyAffordances(node);

    expect(open.status).toBeNull();
    expect(open.split).toBeNull();
    expect(open.delete).toBeNull();
    expect(open.complete).toBe(false);
    await act(async () => root.unmount());
  });
});

describe("an open operation keeps its current behavior", () => {
  it("still offers the open-only controls and has no closed-edit banner", async () => {
    const { node, root } = await render(
      operation({ status: "deposit_verification", beneficiaries: twoRecipients() }),
      { role: "owner", otherOpenOperations: [{ id: "op-2", label: "x" }] },
    );

    expect(button(node, P.changeStatus)).not.toBeNull();
    expect(button(node, P.splitDeposit.button)).not.toBeNull();
    expect(button(node, P.editOperation)).not.toBeNull();
    expect(button(node, P.editBeneficiary)).not.toBeNull();
    expect(button(node, P.moveBeneficiary)).not.toBeNull();
    expect(button(node, P.removeBeneficiary)).not.toBeNull();
    expect(button(node, P.addBeneficiary)).not.toBeNull();
    expect(node.textContent).not.toContain(P.closedEdit.title);
    await act(async () => root.unmount());
  });

  it("an agent keeps the shared edits on an open operation, without the closed banner", async () => {
    const { node, root } = await render(
      operation({ status: "deposit_verification", beneficiaries: twoRecipients() }),
      { role: "agent" },
    );

    expect(button(node, P.editOperation)).not.toBeNull();
    expect(button(node, P.editBeneficiary)).not.toBeNull();
    expect(button(node, P.removeBeneficiary)).not.toBeNull();
    expect(button(node, P.addBeneficiary)).not.toBeNull();
    expect(node.textContent).not.toContain(P.closedEdit.title);
    await act(async () => root.unmount());
  });

  it("a completed history operation is not force-opened: the card only exposes edits when expanded", async () => {
    const { node, root } = await render(closed("completed"), { role: "owner", expanded: false });

    expect(button(node, P.editOperation)).toBeNull();
    expect(button(node, P.addBeneficiary)).toBeNull();
    expect(node.textContent).not.toContain(P.closedEdit.title);
    await act(async () => root.unmount());
  });
});
