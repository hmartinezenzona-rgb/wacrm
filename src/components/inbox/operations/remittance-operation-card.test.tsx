// @vitest-environment jsdom
// Spec: panel-19 operation-card redesign. Header/status chip row are
// unchanged from the prior slice. The expanded card now shows a "Deliver
// to" block: a Zelle beneficiary gets a name line with the edit pencil (and
// reassign, when other operations exist) on the same line; every other
// type has no name line, so the pencil/reassign move to a slim action line
// above its chips. Both render a vertical stack of tap-to-copy chips
// (amount first, then account or card/phone). An amount that's null falls
// back to the operation's auto-calculated `quotedDestinationAmount` only
// when this is the operation's single beneficiary; otherwise (or when both
// are null) an amber "Amount missing" chip opens the operation correction
// form for an editable card. An optional `onCompleteTransfer` renders a
// full-width button once the operation is `ready_to_transfer` and editable.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type {
  RemittanceBeneficiaryRead,
  RemittanceOperationRead,
  RemittanceOperationStatus,
} from "@/lib/remittance-operations/types";

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

const corregirBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: (...args: unknown[]) => corregirBeneficiario(...args),
  reasignarBeneficiario: vi.fn(),
}));

// The deposit review container fetches on mount and owns its own network
// calls (covered by deposit-review-container.test.tsx) — mocked here to a
// stub that surfaces the props the card computes for it (`summaryAmount`,
// `onAddAmount`) via a data attribute and a test-only button, so this
// file's card-only tests stay isolated from that fetch while still being
// able to assert on what the card passes down.
vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: ({
    operationId,
    summaryAmount,
    onAddAmount,
  }: {
    operationId: string;
    summaryAmount?: { kind: "amount"; display: string } | { kind: "missing" } | null;
    onAddAmount?: () => void;
  }) => (
    <div
      data-testid="deposit-review-stub"
      data-operation-id={operationId}
      data-summary-amount={JSON.stringify(summaryAmount ?? null)}
    >
      {onAddAmount && (
        <button type="button" data-testid="deposit-review-add-amount" onClick={onAddAmount}>
          add amount
        </button>
      )}
    </div>
  ),
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
    quotedDestinationRate: null,
    quotedDestinationOrigin: null,
    adminLockedFields: {},
    createdAt: "2026-09-14T00:00:00Z",
    completedAt: null,
    beneficiaries: [],
    ...overrides,
  };
}

function beneficiary(overrides: Partial<RemittanceBeneficiaryRead> = {}): RemittanceBeneficiaryRead {
  return {
    id: "ben-1",
    beneficiaryType: "cuban_card",
    name: null,
    cardNumber: null,
    phone: null,
    zelleAccount: null,
    deliveryMethod: null,
    amount: null,
    amountOrigin: null,
    currency: null,
    position: 1,
    ...overrides,
  };
}

interface RenderOptions {
  canEdit?: boolean;
  role?: "owner" | "admin" | "agent" | "viewer" | null;
  otherOpenOperations?: { id: string; label: string }[];
  onChanged?: () => void;
  expanded?: boolean;
  onToggle?: () => void;
  onCompleteTransfer?: () => void;
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
        role={options.role ?? "agent"}
        otherOpenOperations={options.otherOpenOperations ?? []}
        onChanged={onChanged}
        expanded={options.expanded ?? true}
        onToggle={onToggle}
        onCompleteTransfer={options.onCompleteTransfer}
      />,
    ),
  );
  return { node, root, onChanged, onToggle };
}

function button(node: Element, label: string) {
  return node.querySelector(`button[aria-label="${label}"]`);
}

function stubClipboard(writeText: (value: string) => Promise<void>) {
  Object.defineProperty(navigator, "clipboard", {
    value: { writeText },
    configurable: true,
  });
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function buttonByText(node: Element, text: string): HTMLButtonElement {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as HTMLButtonElement;
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

  it("renders the no-beneficiaries state under the Deliver to heading when the list is empty", async () => {
    const { node, root } = await render(operation({ beneficiaries: [] }));

    expect(node.textContent).toContain(en.Inbox.operationsPanel.deliverTo);
    expect(node.textContent).toContain("No beneficiaries recorded yet");
    await act(async () => root.unmount());
  });

  it("hides the edit-operation affordance when canEdit is false", async () => {
    const { node, root } = await render(operation(), { canEdit: false });

    expect(button(node, en.Inbox.operationsPanel.editOperation)).toBeNull();
    await act(async () => root.unmount());
  });

  it("hides the edit-operation affordance when the operation status is terminal", async () => {
    const { node, root } = await render(operation({ status: "completed" as RemittanceOperationStatus }), {
      canEdit: true,
    });

    expect(button(node, en.Inbox.operationsPanel.editOperation)).toBeNull();
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
    await act(async () => root.unmount());
  });

  it("shows only the source amount and the destination name in the header, never the destination amount", async () => {
    const { node, root } = await render(
      operation({
        quotedSourceAmount: 26000,
        sourceCurrency: "GYD",
        deliveryMethod: "zelle",
        destinationCurrency: "USD",
        quotedDestinationAmount: 100,
      }),
    );
    const toggleButton = node.querySelector("button[aria-expanded]")!;
    expect(toggleButton.textContent).toContain("26,000 GYD");
    expect(toggleButton.textContent).toContain("Zelle");
    expect(toggleButton.textContent).not.toContain("USD");
    expect(toggleButton.textContent).not.toContain("100");
    await act(async () => root.unmount());
  });

  it("does not render the destination amount anywhere when there are no beneficiaries", async () => {
    const { node, root } = await render(operation({ quotedDestinationAmount: 150000, destinationCurrency: "CUP" }));

    expect(node.textContent).not.toContain("150,000");
    await act(async () => root.unmount());
  });

  it("renders a lock icon next to a field present in adminLockedFields", async () => {
    const { node, root } = await render(
      operation({
        destinationCurrency: "USD",
        adminLockedFields: { destination_currency: { by: "admin-1", at: "2026-09-10T00:00:00Z" } },
      }),
    );

    expect(node.querySelector(`[aria-label="${en.Inbox.operationsPanel.lockedByOperator}"]`)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("renders a lock icon next to the Deliver to heading when adminLockedFields.beneficiaries exists", async () => {
    const { node, root } = await render(
      operation({ adminLockedFields: { beneficiaries: { by: "admin-1", at: "2026-09-10T00:00:00Z" } } }),
    );

    const heading = node.querySelector("h4");
    expect(heading?.textContent).toContain(en.Inbox.operationsPanel.deliverTo);
    expect(heading?.querySelector(`[aria-label="${en.Inbox.operationsPanel.lockedByOperator}"]`)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("collapsed: shows amount and status but hides chips, Deliver to and the edit-operation button", async () => {
    const { node, root } = await render(
      operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5355551111" })] }),
      { expanded: false },
    );

    expect(node.textContent).toContain("10,000 GYD");
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

  it("renders the deposit review block above the Deliver to section when expanded", async () => {
    const { node, root } = await render(
      operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5355551111" })] }),
    );

    const stub = node.querySelector('[data-testid="deposit-review-stub"]');
    const heading = node.querySelector("h4");
    expect(stub).not.toBeNull();
    expect(stub!.getAttribute("data-operation-id")).toBe("op-1");
    expect(heading).not.toBeNull();
    expect(stub!.compareDocumentPosition(heading!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    await act(async () => root.unmount());
  });

  describe("Zelle beneficiary: name and account chips, actions on the Deliver to line", () => {
    it("shows the name as a copy chip, with pencil/move on the Deliver to line and no card/phone chips", async () => {
      const writeText = vi.fn().mockResolvedValue(undefined);
      stubClipboard(writeText);
      const { node, root } = await render(
        operation({
          beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" })],
        }),
        { otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      const nameChip = button(node, "Copy Name")!;
      expect(nameChip).not.toBeNull();
      expect(nameChip.textContent).toContain("Yaima Perez");
      expect(nameChip.querySelector("svg")).not.toBeNull();
      await act(async () => nameChip.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("Yaima Perez");

      const edit = button(node, en.Inbox.operationsPanel.editBeneficiary)!;
      const move = button(node, en.Inbox.operationsPanel.moveBeneficiary)!;
      const deliverToLine = node.querySelector("h4")!;
      expect(deliverToLine.textContent).toContain(en.Inbox.operationsPanel.deliverTo);
      expect(deliverToLine.parentElement!.contains(edit)).toBe(true);
      expect(deliverToLine.parentElement!.contains(move)).toBe(true);
      expect(node.querySelector("li")!.contains(edit)).toBe(false);
      expect(node.textContent).not.toContain("9205");
      await act(async () => root.unmount());
    });

    it("falls back to a name-unavailable message when name is null", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: null })] }),
      );

      expect(node.textContent).toContain(en.Inbox.operationsPanel.beneficiaryNameUnavailable);
      await act(async () => root.unmount());
    });

    it("shows an account chip that copies the raw account", async () => {
      const writeText = vi.fn().mockResolvedValue(undefined);
      stubClipboard(writeText);
      const { node, root } = await render(
        operation({
          beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima", zelleAccount: "yaima@example.invalid" })],
        }),
      );

      const chip = button(node, "Copy Zelle account")!;
      await act(async () => chip.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("yaima@example.invalid");
      await act(async () => root.unmount());
    });

    it("hides the pencil/move when canEdit is false", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima" })] }),
        { canEdit: false, otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).toBeNull();
      expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).toBeNull();
      await act(async () => root.unmount());
    });

    it("hides move (but keeps edit) when there are no other open operations", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima" })] }),
        { otherOpenOperations: [] },
      );

      expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).not.toBeNull();
      expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).toBeNull();
      await act(async () => root.unmount());
    });
  });

  describe("Cuba (non-zelle) beneficiary: no name line, slim action line above the chips", () => {
    it("has no name text and shows card + phone chips", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [beneficiary({ name: "Ignored Name", cardNumber: "9205123412349412", phone: "5355551111" })],
        }),
      );

      expect(node.textContent).not.toContain("Ignored Name");
      expect(node.textContent).toContain("9205 1234 1234 9412");
      expect(node.textContent).toContain("5355551111");
      await act(async () => root.unmount());
    });

    it("puts a single beneficiary's pencil/move on the Deliver to line", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", amount: 60000, currency: "CUP" })] }),
        { otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      const edit = button(node, en.Inbox.operationsPanel.editBeneficiary)!;
      const move = button(node, en.Inbox.operationsPanel.moveBeneficiary)!;
      const deliverToLine = node.querySelector("h4")!.parentElement!;
      expect(deliverToLine.contains(edit)).toBe(true);
      expect(deliverToLine.contains(move)).toBe(true);
      expect(edit.closest("li")).toBeNull();
      await act(async () => root.unmount());
    });

    it("puts each beneficiary's pencil/move on its own slim line when there are several", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ id: "b-1", cardNumber: "9205123412349412", amount: 30000, currency: "CUP" }),
            beneficiary({ id: "b-2", cardNumber: "9205999912349412", amount: 30000, currency: "CUP" }),
          ],
        }),
        { otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      const edit = node.querySelectorAll(`button[aria-label="${en.Inbox.operationsPanel.editBeneficiary}"]`)[0] as HTMLButtonElement;
      const move = node.querySelectorAll(`button[aria-label="${en.Inbox.operationsPanel.moveBeneficiary}"]`)[0] as HTMLButtonElement;
      const item = edit.closest("li")!;
      const actionLine = item.firstElementChild!;
      expect(actionLine.contains(edit)).toBe(true);
      expect(actionLine.contains(move)).toBe(true);
      expect(actionLine.textContent?.trim()).toBe("");
      await act(async () => root.unmount());
    });

    it("shows no action line at all when not editable", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412" })] }),
        { canEdit: false },
      );

      expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).toBeNull();
      expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).toBeNull();
      await act(async () => root.unmount());
    });

    it("copies raw card digits (no spaces) and raw phone digits", async () => {
      const writeText = vi.fn().mockResolvedValue(undefined);
      stubClipboard(writeText);
      const { node, root } = await render(
        operation({
          beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5355551111" })],
        }),
      );

      await act(async () => button(node, "Copy Card")!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("9205123412349412");
      await act(async () => button(node, "Copy Phone")!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("5355551111");
      await act(async () => root.unmount());
    });

    it("only shows the card chip when phone is absent, and vice versa", async () => {
      let result = await render(operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: null })] }));
      expect(button(result.node, "Copy Card")).not.toBeNull();
      expect(button(result.node, "Copy Phone")).toBeNull();
      await act(async () => result.root.unmount());

      result = await render(operation({ beneficiaries: [beneficiary({ cardNumber: null, phone: "5355551111" })] }));
      expect(button(result.node, "Copy Card")).toBeNull();
      expect(button(result.node, "Copy Phone")).not.toBeNull();
      await act(async () => result.root.unmount());
    });
  });

  describe("deposit block summary amount", () => {
    function summaryAmountFromStub(node: Element): unknown {
      const stub = node.querySelector('[data-testid="deposit-review-stub"]')!;
      return JSON.parse(stub.getAttribute("data-summary-amount")!);
    }

    it("passes a Zelle-labeled amount for a single Zelle beneficiary, not inside the beneficiary block", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Maria", amount: 100, currency: "USD" })],
        }),
      );

      expect(summaryAmountFromStub(node)).toEqual({ kind: "amount", display: "100 Zelle" });
      const list = node.querySelector("ul")!;
      expect(list.textContent).not.toContain("100");
      expect(button(node, "Copy Amount")).toBeNull();
      await act(async () => root.unmount());
    });

    it("passes a currency-labeled amount for a single non-Zelle beneficiary", async () => {
      const { node, root } = await render(operation({ beneficiaries: [beneficiary({ amount: 60000, currency: "CUP" })] }));

      expect(summaryAmountFromStub(node)).toEqual({ kind: "amount", display: "60,000 CUP" });
      await act(async () => root.unmount());
    });

    it("falls back to the operation's quotedDestinationAmount for the single beneficiary", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationAmount: 9800.5,
          destinationCurrency: "CUP",
          beneficiaries: [beneficiary({ amount: null, currency: null })],
        }),
      );

      expect(summaryAmountFromStub(node)).toEqual({ kind: "amount", display: "9,800.5 CUP" });
      await act(async () => root.unmount());
    });

    it("passes a missing amount for the single beneficiary when neither it nor the operation has one", async () => {
      const { node, root } = await render(operation({ beneficiaries: [beneficiary({ amount: null })] }));

      expect(summaryAmountFromStub(node)).toEqual({ kind: "missing" });
      await act(async () => root.unmount());
    });

    it("passes the operation-level amount when there are no beneficiaries", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [], quotedDestinationAmount: 150000, destinationCurrency: "CUP" }),
      );

      expect(summaryAmountFromStub(node)).toEqual({ kind: "amount", display: "150,000 CUP" });
      await act(async () => root.unmount());
    });

    it("passes null (no top row) when there are no beneficiaries and no operation amount", async () => {
      const { node, root } = await render(operation({ beneficiaries: [] }));

      expect(summaryAmountFromStub(node)).toBeNull();
      await act(async () => root.unmount());
    });

    it("passes null (no top row) for two or more beneficiaries, even with amounts", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationAmount: 9800.5,
          destinationCurrency: "CUP",
          beneficiaries: [
            beneficiary({ id: "ben-1", amount: 500, currency: "CUP" }),
            beneficiary({ id: "ben-2", amount: 700, currency: "CUP" }),
          ],
        }),
      );

      expect(summaryAmountFromStub(node)).toBeNull();
      await act(async () => root.unmount());
    });

    it("wires onAddAmount to open the operation correction form when editable", async () => {
      const { node, root } = await render(operation({ beneficiaries: [beneficiary({ amount: null })] }), {
        canEdit: true,
      });

      const addAmount = node.querySelector('[data-testid="deposit-review-add-amount"]') as HTMLButtonElement;
      expect(addAmount).not.toBeNull();
      await act(async () => addAmount.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(node.querySelector("#operation-quoted-source-amount")).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("does not pass onAddAmount when the card is not editable", async () => {
      const { node, root } = await render(operation({ beneficiaries: [beneficiary({ amount: null })] }), {
        canEdit: false,
      });

      expect(node.querySelector('[data-testid="deposit-review-add-amount"]')).toBeNull();
      await act(async () => root.unmount());
    });

    it("never shows 'calculated' text anywhere", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationAmount: 100,
          quotedDestinationRate: 120,
          quotedDestinationOrigin: "calculated",
          destinationCurrency: "USD",
          beneficiaries: [beneficiary({ amount: null, currency: null })],
        }),
      );

      expect(node.textContent).not.toContain("calculated");
      await act(async () => root.unmount());
    });
  });

  describe("per-beneficiary amount row (2+ beneficiaries)", () => {
    it("shows each beneficiary's own amount as a plain, non-copyable row above its chips", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ id: "ben-1", cardNumber: "9205123412349412", amount: 500, currency: "CUP" }),
            beneficiary({ id: "ben-2", cardNumber: "1111222233334444", amount: 700, currency: "CUP" }),
          ],
        }),
      );

      expect(node.textContent).toContain("500 CUP");
      expect(node.textContent).toContain("700 CUP");
      expect(button(node, "Copy Amount")).toBeNull();
      await act(async () => root.unmount());
    });

    it("shows no amount row and no missing-amount warning for a beneficiary without an amount", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ id: "ben-1", cardNumber: "9205123412349412", amount: null }),
            beneficiary({ id: "ben-2", cardNumber: "1111222233334444", amount: 700, currency: "CUP" }),
          ],
        }),
      );

      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.amountMissing);
      expect(node.textContent).toContain("700 CUP");
      await act(async () => root.unmount());
    });
  });

  describe("Complete transfer button", () => {
    function readyOperation(overrides: Partial<RemittanceOperationRead> = {}) {
      return operation({ status: "ready_to_transfer", ...overrides });
    }

    it("is absent when onCompleteTransfer is not provided", async () => {
      const { node, root } = await render(readyOperation());
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.completeTransfer);
      await act(async () => root.unmount());
    });

    it("renders full-width and calls onCompleteTransfer when provided, ready_to_transfer and editable", async () => {
      const onCompleteTransfer = vi.fn();
      const { node, root } = await render(readyOperation(), { onCompleteTransfer, canEdit: true });

      const completeButton = Array.from(node.querySelectorAll("button")).find(
        (b) => b.textContent?.trim() === en.Inbox.operationsPanel.completeTransfer,
      ) as HTMLButtonElement;
      expect(completeButton).not.toBeUndefined();

      await act(async () => completeButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(onCompleteTransfer).toHaveBeenCalledTimes(1);
      await act(async () => root.unmount());
    });

    it("is absent when the status is not ready_to_transfer", async () => {
      const onCompleteTransfer = vi.fn();
      const { node, root } = await render(operation({ status: "deposit_verification" }), { onCompleteTransfer });
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.completeTransfer);
      await act(async () => root.unmount());
    });

    it("is absent when the card is not editable", async () => {
      const onCompleteTransfer = vi.fn();
      const { node, root } = await render(readyOperation(), { onCompleteTransfer, canEdit: false });
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.completeTransfer);
      await act(async () => root.unmount());
    });
  });

  describe("Beneficiary inline edit", () => {
    it("zelle: pencil shows prefilled Name + Zelle account inputs, hides their chips, shows Save/Cancel and no select", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" }),
          ],
        }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );

      const nameInput = node.querySelector<HTMLInputElement>("#inline-name-ben-1")!;
      const accountInput = node.querySelector<HTMLInputElement>("#inline-zelle-account-ben-1")!;
      expect(nameInput.value).toBe("Yaima Perez");
      expect(accountInput.value).toBe("yaima@example.invalid");
      expect(button(node, "Copy Name")).toBeNull();
      expect(button(node, "Copy Zelle account")).toBeNull();
      expect(node.querySelector("select")).toBeNull();
      expect(buttonByText(node, en.Inbox.operationsPanel.save)).not.toBeUndefined();
      expect(buttonByText(node, en.Inbox.operationsPanel.cancel)).not.toBeUndefined();

      await act(async () => root.unmount());
    });

    it("change name → Save calls corregirBeneficiario with only the name key, exits edit mode, calls onChanged", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
      const onChanged = vi.fn();
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" }),
          ],
        }),
        { onChanged },
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      const nameInput = node.querySelector<HTMLInputElement>("#inline-name-ben-1")!;
      await act(async () => setValue(nameInput, "New Name"));
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: "New Name" });
      expect(onChanged).toHaveBeenCalled();
      expect(node.querySelector("#inline-name-ben-1")).toBeNull();
      await act(async () => root.unmount());
    });

    it("no change → Save exits edit mode without calling the API", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" }),
          ],
        }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector("#inline-name-ben-1")).toBeNull();
      await act(async () => root.unmount());
    });

    it("Cancel restores the chips without calling the API", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" }),
          ],
        }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      const nameInput = node.querySelector<HTMLInputElement>("#inline-name-ben-1")!;
      await act(async () => setValue(nameInput, "Changed Name"));
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.cancel).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector("#inline-name-ben-1")).toBeNull();
      expect(button(node, "Copy Name")!.textContent).toContain("Yaima Perez");
      await act(async () => root.unmount());
    });

    it("Escape restores the chips without calling the API", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" }),
          ],
        }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      const nameInput = node.querySelector<HTMLInputElement>("#inline-name-ben-1")!;
      await act(async () =>
        nameInput.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
      );

      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector("#inline-name-ben-1")).toBeNull();
      await act(async () => root.unmount());
    });

    it("cuba: a 15-digit card shows an alert and does not call the API", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5355551111" })] }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      const cardInput = node.querySelector<HTMLInputElement>("#inline-card-ben-1")!;
      await act(async () => setValue(cardInput, "123456789012345"));
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector('[role="alert"]')?.textContent).toBe(en.Inbox.operationsPanel.invalidCard);
      await act(async () => root.unmount());
    });

    it("cuba: a valid card change sends digits-only card_number", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5355551111" })] }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      const cardInput = node.querySelector<HTMLInputElement>("#inline-card-ben-1")!;
      await act(async () => setValue(cardInput, "1111 2222 3333 4444"));
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { card_number: "1111222233334444" });
      await act(async () => root.unmount());
    });

    it("shows the API error and stays in edit mode on failure", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: false, status: 409, error: "Beneficiary locked" });
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" }),
          ],
        }),
      );

      await act(async () =>
        button(node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      const nameInput = node.querySelector<HTMLInputElement>("#inline-name-ben-1")!;
      await act(async () => setValue(nameInput, "New Name"));
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(node.querySelector('[role="alert"]')?.textContent).toBe("Beneficiary locked");
      expect(node.querySelector("#inline-name-ben-1")).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("editing one beneficiary of two leaves the other block's chips intact", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ id: "b-1", cardNumber: "9205123412349412", amount: 30000, currency: "CUP" }),
            beneficiary({ id: "b-2", cardNumber: "9205999912349412", amount: 30000, currency: "CUP" }),
          ],
        }),
        { otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      const edits = node.querySelectorAll(`button[aria-label="${en.Inbox.operationsPanel.editBeneficiary}"]`);
      await act(async () => edits[0]!.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(node.querySelector("#inline-card-b-1")).not.toBeNull();
      expect(button(node, "Copy Card")).not.toBeNull();
      expect(node.textContent).toContain("9205 9999 1234 9412");
      await act(async () => root.unmount());
    });

    it("2+ beneficiaries: editing a block with an amount row shows an Amount input and sends only the amount when changed", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "b-1" });
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ id: "b-1", cardNumber: "9205123412349412", amount: 30000, currency: "CUP" }),
            beneficiary({ id: "b-2", cardNumber: "9205999912349412", amount: 30000, currency: "CUP" }),
          ],
        }),
      );

      const edits = node.querySelectorAll(`button[aria-label="${en.Inbox.operationsPanel.editBeneficiary}"]`);
      await act(async () => edits[0]!.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      const amountInput = node.querySelector<HTMLInputElement>("#inline-amount-b-1")!;
      expect(amountInput.value).toBe("30000");
      await act(async () => setValue(amountInput, "45000"));
      await act(async () =>
        buttonByText(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(corregirBeneficiario).toHaveBeenCalledWith("b-1", { amount: 45000 });
      await act(async () => root.unmount());
    });

    it("canEdit false: no pencil and no way to open inline edit", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez" })] }),
        { canEdit: false },
      );

      expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).toBeNull();
      expect(node.querySelector("#inline-name-ben-1")).toBeNull();
      await act(async () => root.unmount());
    });
  });
});
