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

vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: vi.fn(),
  reasignarBeneficiario: vi.fn(),
}));

// The deposit review container fetches on mount and owns its own network
// calls (covered by deposit-review-container.test.tsx) — mocked here to a
// plain, textless marker so this file's card-only tests stay isolated
// from that fetch and every existing textContent assertion below.
vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: ({ operationId }: { operationId: string }) => (
    <div data-testid="deposit-review-stub" data-operation-id={operationId} />
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

  describe("Zelle beneficiary: name line with pencil/reassign on the same line", () => {
    it("shows the name, edit pencil and no card/phone chips", async () => {
      const { node, root } = await render(
        operation({
          beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima Perez", zelleAccount: "yaima@example.invalid" })],
        }),
        { otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      expect(node.textContent).toContain("Yaima Perez");
      const edit = button(node, en.Inbox.operationsPanel.editBeneficiary)!;
      const move = button(node, en.Inbox.operationsPanel.moveBeneficiary)!;
      expect(edit).not.toBeNull();
      expect(move).not.toBeNull();
      const nameLine = node.querySelector("li > div")!;
      expect(nameLine.textContent).toContain("Yaima Perez");
      expect(nameLine.contains(edit)).toBe(true);
      expect(nameLine.contains(move)).toBe(true);
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

    it("puts the pencil/move on their own slim line above the chips when editable", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", amount: 60000, currency: "CUP" })] }),
        { otherOpenOperations: [{ id: "op-2", label: "x" }] },
      );

      const edit = button(node, en.Inbox.operationsPanel.editBeneficiary)!;
      const move = button(node, en.Inbox.operationsPanel.moveBeneficiary)!;
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

  describe("amount chip", () => {
    it("labels a Zelle beneficiary amount as Zelle instead of its currency, and copies the raw number", async () => {
      const writeText = vi.fn().mockResolvedValue(undefined);
      stubClipboard(writeText);
      const { node, root } = await render(
        operation({
          beneficiaries: [
            beneficiary({ beneficiaryType: "zelle", name: "Maria", amount: 100, currency: "USD" }),
          ],
        }),
      );

      expect(node.textContent).toContain("100 Zelle");
      expect(node.textContent).not.toContain("100 USD");
      await act(async () => button(node, "Copy Amount")!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("100");
      await act(async () => root.unmount());
    });

    it("shows a non-Zelle amount formatted with its currency and copies the unformatted number", async () => {
      const writeText = vi.fn().mockResolvedValue(undefined);
      stubClipboard(writeText);
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ amount: 60000, currency: "CUP" })] }),
      );

      expect(node.textContent).toContain("60,000 CUP");
      await act(async () => button(node, "Copy Amount")!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("60000");
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

      expect(node.textContent).toContain("9,800.5 CUP");
      await act(async () => root.unmount());
    });

    it("shows the amount-missing warning chip (not the operation fallback) when there are multiple beneficiaries", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationAmount: 9800.5,
          destinationCurrency: "CUP",
          beneficiaries: [
            beneficiary({ id: "ben-1", amount: null }),
            beneficiary({ id: "ben-2", amount: 500, currency: "CUP" }),
          ],
        }),
      );

      expect(node.textContent).not.toContain("9,800.5");
      const warnings = Array.from(node.querySelectorAll("button")).filter(
        (b) => b.textContent?.trim() === en.Inbox.operationsPanel.amountMissing,
      );
      expect(warnings).toHaveLength(1);
      await act(async () => root.unmount());
    });

    it("opens the operation correction form when the amount-missing chip is tapped and the card is editable", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ amount: null })] }),
        { canEdit: true },
      );

      const warning = Array.from(node.querySelectorAll("button")).find(
        (b) => b.textContent?.trim() === en.Inbox.operationsPanel.amountMissing,
      )!;
      await act(async () => warning.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(node.querySelector("#operation-quoted-source-amount")).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("makes the amount-missing chip inert (disabled) for a read-only card", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ amount: null })] }),
        { canEdit: false },
      );

      const warning = Array.from(node.querySelectorAll("button")).find(
        (b) => b.textContent?.trim() === en.Inbox.operationsPanel.amountMissing,
      ) as HTMLButtonElement;
      expect(warning.disabled).toBe(true);
      await act(async () => root.unmount());
    });

    it("shows the calculated-divide hint for a non-CUP calculated amount", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationAmount: 100,
          quotedDestinationRate: 120,
          quotedDestinationOrigin: "calculated",
          destinationCurrency: "USD",
          beneficiaries: [beneficiary({ amount: null, currency: null })],
        }),
      );

      expect(node.textContent).toContain("calculated ÷120");
      await act(async () => root.unmount());
    });

    it("shows the calculated-multiply hint for a CUP calculated amount", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationAmount: 24000,
          quotedDestinationRate: 240,
          quotedDestinationOrigin: "calculated",
          destinationCurrency: "CUP",
          beneficiaries: [beneficiary({ amount: null, currency: null })],
        }),
      );

      expect(node.textContent).toContain("calculated ×240");
      await act(async () => root.unmount());
    });

    it("shows a lock icon instead of the calculated hint when the origin is manual", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ amount: 500, amountOrigin: "manual", currency: "CUP" })] }),
      );

      expect(node.textContent).not.toContain("calculated");
      expect(node.querySelector(`[aria-label="${en.Inbox.operationsPanel.manualAmount}"]`)).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("shows a lock icon when the operation admin-locks quoted_destination_amount, even if origin is calculated", async () => {
      const { node, root } = await render(
        operation({
          quotedDestinationRate: 120,
          quotedDestinationOrigin: "calculated",
          adminLockedFields: { quoted_destination_amount: { by: "admin-1", at: "2026-09-10T00:00:00Z" } },
          beneficiaries: [beneficiary({ amount: 500, currency: "USD" })],
        }),
      );

      expect(node.textContent).not.toContain("calculated");
      expect(node.querySelector(`[aria-label="${en.Inbox.operationsPanel.manualAmount}"]`)).not.toBeNull();
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
});
