// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel ("List All Open Remesas Per
// Conversation") plus the correction/reassignment UI: edit/move
// affordances gate on `canEdit` and non-terminal status, and
// `adminLockedFields` renders a lock indicator next to the locked field
// (or the beneficiaries heading). Edit/move affordances are icon-only
// buttons identified by `aria-label`, not visible text. The card is a
// collapsible accordion header (owned by the panel container via
// `expanded`/`onToggle`): only the details (chips, beneficiaries) show
// when expanded. Cuba beneficiary types (every type except "zelle") have
// no name, only card + phone (shown in full, with a copy button); "zelle"
// always has a name + Zelle account and no card/phone.

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
  expanded?: boolean;
  onToggle?: () => void;
}

async function render(op: RemittanceOperationRead, options: RenderOptions = {}) {
  const { RemittanceOperationCard } = await import("./remittance-operation-card");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onChanged = options.onChanged ?? vi.fn();
  const onToggle = options.onToggle ?? vi.fn();
  await act(async () =>
    root.render(
      <RemittanceOperationCard
        operation={op}
        canEdit={options.canEdit ?? true}
        otherOpenOperations={options.otherOpenOperations ?? []}
        onChanged={onChanged}
        expanded={options.expanded ?? true}
        onToggle={onToggle}
      />,
    ),
  );
  return { node, root, onChanged, onToggle };
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

  it("renders every beneficiary: cuban_card has no name and shows full card/phone; zelle has name + account and no card/phone", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: "Yaima Cuba Card",
            cardNumber: "9205123412349412",
            phone: "5355551111",
            zelleAccount: null,
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 1,
          },
          {
            id: "ben-2",
            beneficiaryType: "zelle",
            name: "Yaima Zelle Account",
            cardNumber: null,
            phone: null,
            zelleAccount: "yaima@example.invalid",
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 2,
          },
        ],
      }),
    );

    // Cuba beneficiary types (every type except zelle) have no name.
    expect(node.textContent).not.toContain("Yaima Cuba Card");
    expect(node.textContent).toContain("9205 1234 1234 9412");
    expect(node.textContent).toContain("5355551111");
    // Zelle beneficiaries always have a name + Zelle account, no card/phone.
    expect(node.textContent).toContain("Yaima Zelle Account");
    expect(node.textContent).toContain("yaima@example.invalid");
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

    expect(node.textContent).toContain("CUP");
    expect(node.textContent).toContain("MMG");
    expect(node.textContent).not.toContain("cuban_card");
    expect(node.textContent).not.toContain("mmg");
    expect(node.textContent).not.toContain("Cuban card");
    await act(async () => root.unmount());
  });

  it("shows only the deposited amount and the destination name in the header", async () => {
    let result = await render(
      operation({
        quotedSourceAmount: 26000,
        sourceCurrency: "GYD",
        deliveryMethod: "zelle",
        destinationCurrency: "USD",
        quotedDestinationAmount: 100,
      }),
    );
    let toggleButton = result.node.querySelector("button[aria-expanded]")!;
    expect(toggleButton.textContent).toContain("26,000 GYD");
    expect(toggleButton.textContent).toContain("Zelle");
    expect(toggleButton.textContent).not.toContain("USD");
    expect(toggleButton.textContent).not.toContain("100");
    await act(async () => result.root.unmount());

    result = await render(operation({ deliveryMethod: "clasica" }));
    toggleButton = result.node.querySelector("button[aria-expanded]")!;
    expect(toggleButton.textContent).toContain("Classic");
    await act(async () => result.root.unmount());

    result = await render(
      operation({
        deliveryMethod: "cuban_card",
        destinationCurrency: null,
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: null,
            cardNumber: "9205123412349412",
            phone: null,
            zelleAccount: null,
            deliveryMethod: null,
            amount: null,
            currency: "MLC",
            position: 1,
          },
        ],
      }),
    );
    toggleButton = result.node.querySelector("button[aria-expanded]")!;
    expect(toggleButton.textContent).toContain("MLC");
    await act(async () => result.root.unmount());
  });

  it("does not render the destination amount anywhere", async () => {
    const { node, root } = await render(
      operation({ quotedDestinationAmount: 150000, destinationCurrency: "CUP" }),
    );

    expect(node.textContent).not.toContain("150,000");
    await act(async () => root.unmount());
  });

  it("renders the quoted source amount only once", async () => {
    const { node, root } = await render(operation({ quotedSourceAmount: 10000, sourceCurrency: "GYD" }));

    expect(node.textContent!.split("10,000 GYD").length - 1).toBe(1);
    await act(async () => root.unmount());
  });

  it("does not render beneficiary type badges", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "multiple_distribution",
            name: null,
            cardNumber: "9205123412349412",
            phone: "5355551111",
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
            cardNumber: null,
            phone: null,
            zelleAccount: "yaima@example.invalid",
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 2,
          },
        ],
      }),
    );

    expect(node.querySelector('[aria-label="Multiple distribution"]')).toBeNull();
    expect(node.querySelector('[aria-label="Zelle"]')).toBeNull();
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

  it("collapsed: shows amount and status but hides chips, beneficiaries and the edit-operation button", async () => {
    const { node, root } = await render(
      operation({
        deliveryMethod: "cuban_card",
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: null,
            cardNumber: "9205123412349412",
            phone: "5355551111",
            zelleAccount: null,
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 1,
          },
        ],
      }),
      { expanded: false },
    );

    expect(node.textContent).toContain("10,000 GYD");
    expect(node.textContent).toContain("Deposit verification");
    const toggleButton = node.querySelector("button[aria-expanded]")!;
    expect(toggleButton.getAttribute("aria-expanded")).toBe("false");
    expect(node.querySelector("h4")).toBeNull();
    expect(node.textContent).not.toContain("9205 1234 1234 9412");
    expect(button(node, en.Inbox.operationsPanel.editOperation)).toBeNull();
    await act(async () => root.unmount());
  });

  it("calls onToggle once when the header button is clicked", async () => {
    const { node, onToggle } = await render(operation(), { expanded: false });

    const toggleButton = node.querySelector("button[aria-expanded]")!;
    await act(async () => {
      toggleButton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onToggle).toHaveBeenCalledTimes(1);
  });

  it("shows copy buttons with the expected aria-labels for card/phone and name/zelle account", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: null,
            cardNumber: "9205123412349412",
            phone: "5355551111",
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
            cardNumber: null,
            phone: null,
            zelleAccount: "yaima@example.invalid",
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 2,
          },
        ],
      }),
    );

    expect(button(node, "Copy Card")).not.toBeNull();
    expect(button(node, "Copy Phone")).not.toBeNull();
    expect(button(node, "Copy Name")).not.toBeNull();
    expect(button(node, "Copy Zelle account")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("renders the beneficiary amount row with edit and move actions", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: null,
            cardNumber: "9205123412349412",
            phone: "5355551111",
            zelleAccount: null,
            deliveryMethod: null,
            amount: 60000,
            currency: "CUP",
            position: 1,
          },
        ],
      }),
      { canEdit: true, otherOpenOperations: [{ id: "op-2", label: "x" }] },
    );

    expect(node.textContent).toContain("60,000 CUP");
    expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).not.toBeNull();
    expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("status chip row is outside the toggle button", async () => {
    const { node, root } = await render(operation({ status: "deposit_verification" }));

    const toggleButton = node.querySelector("button[aria-expanded]")!;
    expect(toggleButton.textContent).not.toContain(en.Inbox.operationsPanel.status.deposit_verification);
    expect(node.textContent).toContain(en.Inbox.operationsPanel.status.deposit_verification);
    await act(async () => root.unmount());
  });
});
