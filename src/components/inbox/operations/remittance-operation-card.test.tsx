// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel ("List All Open Remesas Per
// Conversation") plus the correction/reassignment UI: edit/move
// affordances gate on `canEdit` and non-terminal status, and
// `adminLockedFields` renders a lock indicator next to the locked field
// (or the beneficiaries heading). Edit/move affordances are icon-only
// buttons identified by `aria-label`, not visible text.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceOperationRead, RemittanceOperationStatus } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: vi.fn(),
  reasignarBeneficiario: vi.fn(),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

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
    adminLockedFields: {},
    createdAt: "2026-09-14T00:00:00Z",
    completedAt: null,
    beneficiaries: [],
    ...overrides,
  };
}

interface RenderOptions {
  canEdit?: boolean;
  otherOpenOperations?: { id: string; label: string }[];
  onChanged?: () => void;
}

async function render(op: RemittanceOperationRead, options: RenderOptions = {}) {
  const { RemittanceOperationCard } = await import("./remittance-operation-card");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onChanged = options.onChanged ?? vi.fn();
  await act(async () =>
    root.render(
      <RemittanceOperationCard
        operation={op}
        canEdit={options.canEdit ?? true}
        otherOpenOperations={options.otherOpenOperations ?? []}
        onChanged={onChanged}
      />,
    ),
  );
  return { node, root, onChanged };
}

function button(node: Element, label: string) {
  return node.querySelector(`button[aria-label="${label}"]`);
}

describe("RemittanceOperationCard", () => {
  it("renders the source amount and the status label", async () => {
    const { node, root } = await render(
      operation({ quotedSourceAmount: 10000, sourceCurrency: "GYD", status: "deposit_verification" }),
    );

    expect(node.textContent).toContain("10,000 GYD");
    expect(node.textContent).toContain("Deposit verification");
    await act(async () => root.unmount());
  });

  it("renders every beneficiary of a multi-beneficiary remesa with masked card/phone", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: "Yaima Perez",
            cardNumberMasked: "9205****9412",
            phoneMasked: "*******1111",
            zelleAccount: null,
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 1,
          },
          {
            id: "ben-2",
            beneficiaryType: "zelle",
            name: "Yaima Perez Zelle",
            cardNumberMasked: null,
            phoneMasked: null,
            zelleAccount: "yaima@example.invalid",
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 2,
          },
        ],
      }),
    );

    expect(node.textContent).toContain("Yaima Perez");
    expect(node.textContent).toContain("9205****9412");
    expect(node.textContent).toContain("*******1111");
    expect(node.textContent).toContain("Yaima Perez Zelle");
    expect(node.textContent).toContain("yaima@example.invalid");
    // Never a raw card/phone value, only the masked form.
    expect(node.textContent).not.toContain("92051234");
    await act(async () => root.unmount());
  });

  it("renders the no-beneficiaries state when the list is empty (triangulation)", async () => {
    const { node, root } = await render(operation({ beneficiaries: [] }));

    expect(node.textContent).toContain("No beneficiaries recorded yet");
    await act(async () => root.unmount());
  });

  it("hides edit/move affordances when canEdit is false", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
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
      }),
      { canEdit: false, otherOpenOperations: [{ id: "op-2", label: "5,000 GYD → USD" }] },
    );

    expect(button(node, en.Inbox.operationsPanel.editOperation)).toBeNull();
    expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).toBeNull();
    expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).toBeNull();
    await act(async () => root.unmount());
  });

  it("hides edit/move affordances when the operation status is terminal", async () => {
    const { node, root } = await render(
      operation({ status: "completed" as RemittanceOperationStatus }),
      { canEdit: true, otherOpenOperations: [{ id: "op-2", label: "5,000 GYD → USD" }] },
    );

    expect(button(node, en.Inbox.operationsPanel.editOperation)).toBeNull();
    await act(async () => root.unmount());
  });

  it("hides the move button when there are no other open operations", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
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
      }),
      { canEdit: true, otherOpenOperations: [] },
    );

    expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).not.toBeNull();
    expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).toBeNull();
    await act(async () => root.unmount());
  });

  it("shows icon-only edit and move buttons when editable with other open operations", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
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
      }),
      { canEdit: true, otherOpenOperations: [{ id: "op-2", label: "x" }] },
    );

    const editOperationBtn = button(node, en.Inbox.operationsPanel.editOperation);
    const editBeneficiaryBtn = button(node, en.Inbox.operationsPanel.editBeneficiary);
    const moveBeneficiaryBtn = button(node, en.Inbox.operationsPanel.moveBeneficiary);

    expect(editOperationBtn).not.toBeNull();
    expect(editBeneficiaryBtn).not.toBeNull();
    expect(moveBeneficiaryBtn).not.toBeNull();
    expect(editOperationBtn!.querySelector("svg")).not.toBeNull();
    expect(editBeneficiaryBtn!.querySelector("svg")).not.toBeNull();
    expect(moveBeneficiaryBtn!.querySelector("svg")).not.toBeNull();
    expect(node.textContent).not.toContain(en.Inbox.operationsPanel.editOperation);
    await act(async () => root.unmount());
  });

  it("renders human labels instead of raw method values", async () => {
    const { node, root } = await render(
      operation({ deliveryMethod: "cuban_card", depositMethod: "mmg", destinationCurrency: "CUP" }),
    );

    expect(node.textContent).toContain("Cuban card");
    expect(node.textContent).toContain("MMG");
    expect(node.textContent).toContain("CUP");
    expect(node.textContent).not.toContain("cuban_card");
    expect(node.textContent).not.toContain("mmg");
    await act(async () => root.unmount());
  });

  it("renders the quoted source amount only once", async () => {
    const { node, root } = await render(operation({ quotedSourceAmount: 10000, sourceCurrency: "GYD" }));

    expect(node.textContent!.split("10,000 GYD").length - 1).toBe(1);
    await act(async () => root.unmount());
  });

  it("renders a method badge per beneficiary type", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: "Yaima Perez",
            cardNumberMasked: "9205****9412",
            phoneMasked: "*******1111",
            zelleAccount: null,
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 1,
          },
          {
            id: "ben-2",
            beneficiaryType: "zelle",
            name: "Yaima Perez Zelle",
            cardNumberMasked: null,
            phoneMasked: null,
            zelleAccount: "yaima@example.invalid",
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 2,
          },
        ],
      }),
    );

    const cubanCardBadge = node.querySelector('[aria-label="Cuban card"]');
    const zelleBadge = node.querySelector('[aria-label="Zelle"]');
    expect(cubanCardBadge).not.toBeNull();
    expect(zelleBadge).not.toBeNull();
    expect(zelleBadge!.textContent).toBe("Z");
    await act(async () => root.unmount());
  });

  it("renders a lock icon next to a field present in adminLockedFields", async () => {
    const { node, root } = await render(
      operation({
        destinationCurrency: "USD",
        adminLockedFields: { destination_currency: { by: "admin-1", at: "2026-09-10T00:00:00Z" } },
      }),
    );

    const lockedEl = node.querySelector(`[aria-label="${en.Inbox.operationsPanel.lockedByOperator}"]`);
    expect(lockedEl).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("renders a lock icon next to the beneficiaries heading when adminLockedFields.beneficiaries exists", async () => {
    const { node, root } = await render(
      operation({
        adminLockedFields: { beneficiaries: { by: "admin-1", at: "2026-09-10T00:00:00Z" } },
      }),
    );

    const heading = node.querySelector("h4");
    expect(heading?.querySelector(`[aria-label="${en.Inbox.operationsPanel.lockedByOperator}"]`)).not.toBeNull();
    await act(async () => root.unmount());
  });
});
