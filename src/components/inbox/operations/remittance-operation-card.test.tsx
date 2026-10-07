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
  ConversationQuoteRead,
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
  fetchCalculatorRates: vi.fn().mockResolvedValue(null),
  corregirOperacion: vi.fn(),
  corregirBeneficiario: (...args: unknown[]) => corregirBeneficiario(...args),
  reasignarBeneficiario: vi.fn(),
  agregarBeneficiario: vi.fn(),
}));

// BeneficiaryAddControl owns its own field-level behavior (covered by
// beneficiary-add-control.test.tsx) — stubbed here so this file only
// asserts on what the card passes down and how it toggles the control.
const BeneficiaryAddControl = vi.fn(
  ({ onDone, onCancel, serviceType, service }: { operationId: string; serviceType?: string; service?: string | null; onDone: () => void; onCancel: () => void }) => (
    <div data-testid="add-beneficiary-stub" data-service-type={serviceType ?? ""} data-service={service ?? ""}>
      <button type="button" data-testid="add-beneficiary-done" onClick={onDone}>
        done
      </button>
      <button type="button" data-testid="add-beneficiary-cancel" onClick={onCancel}>
        cancel
      </button>
    </div>
  ),
);
vi.mock("./beneficiary-add-control", () => ({
  BeneficiaryAddControl: (props: unknown) => BeneficiaryAddControl(props as never),
}));

// The deposit review container fetches on mount and owns its own network
// calls (covered by deposit-review-container.test.tsx) — mocked here to a
// stub that surfaces the props the card computes for it (`summaryAmount`,
// `onAddAmount`) via a data attribute and a test-only button, so this
// file's card-only tests stay isolated from that fetch while still being
// able to assert on what the card passes down.
vi.mock("./combo-cost-field", () => ({
  ComboCostField: ({ costGyd, completed }: { costGyd: number | null; completed: boolean }) => (
    <div data-testid="combo-cost-stub" data-cost={String(costGyd)} data-completed={String(completed)} />
  ),
}));

const CompleteTransferContainer = vi.fn(
  ({ onDone, onCancel }: { operationId: string; conversationId: string; isZelle: boolean; onDone: () => void; onCancel: () => void }) => (
    <div data-testid="complete-transfer-stub">
      <button type="button" data-testid="complete-transfer-done" onClick={onDone}>
        done
      </button>
      <button type="button" data-testid="complete-transfer-cancel" onClick={onCancel}>
        cancel
      </button>
    </div>
  ),
);
vi.mock("./complete-transfer-container", () => ({
  CompleteTransferContainer: (props: unknown) => CompleteTransferContainer(props as never),
}));

vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: ({
    operationId,
    canEdit,
    role,
    summaryAmount,
    onAddAmount,
  }: {
    operationId: string;
    canEdit: boolean;
    role: string | null;
    summaryAmount?: { kind: "amount"; display: string } | { kind: "missing" } | null;
    onAddAmount?: () => void;
  }) => (
    <div
      data-testid="deposit-review-stub"
      data-operation-id={operationId}
      data-can-edit={String(canEdit)}
      data-role={role ?? ""}
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

// The inline reason form owns its own command calls (covered by
// operation-closing-control.test.tsx) — stubbed so this file asserts only on
// when the card offers each action and which kind it opens.
vi.mock("./operation-closing-control", () => ({
  OperationClosingControl: ({ kind, onDone }: { kind: string; onDone: () => void }) => (
    <div data-testid="closing-stub" data-kind={kind}>
      <button type="button" data-testid="closing-done" onClick={onDone}>
        done
      </button>
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
    isHistory: false,
    // Defaults to complete so the many status/editability-focused tests in
    // this file (which don't care about readiness) don't also have to
    // opt in — `effectiveStatus` demotes ready_to_transfer/transferring to
    // awaiting_beneficiary otherwise. Tests for that demotion set it
    // explicitly.
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
    address: null,
    reference: null,
    contactPhone: null,
    idPhotoWamid: null,
    idPhotoUrl: null,
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
  conversationId?: string;
  quote?: ConversationQuoteRead | null;
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
        conversationId={options.conversationId ?? "conv-1"}
        quote={options.quote}
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

/** Icon-only buttons (check / X) are found by their accessible name, never by visible text. */
function buttonByLabel(node: Element, label: string): HTMLButtonElement {
  return node.querySelector(`button[aria-label="${label}"]`) as HTMLButtonElement;
}

function buttonByText(node: Element, text: string): HTMLButtonElement {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as HTMLButtonElement;
}

describe("RemittanceOperationCard visa", () => {
  const visaOp = (overrides: Partial<RemittanceOperationRead> = {}) =>
    operation({
      serviceType: "visa",
      status: "ready_to_transfer",
      quotedSourceAmount: 15000,
      sourceCurrency: "GYD",
      beneficiaries: [],
      ...overrides,
    });

  it("shows the Visa extension label with its icon and the count from the amount, with no quote line", async () => {
    const { node, root } = await render(visaOp(), {
      quote: { gyd: 15000, destinationAmount: 4000, destinationCurrency: "CUP", quotedAt: "2026-10-03T00:00:00Z" },
    });

    expect(node.querySelector("article")!.textContent).toContain("15,000 GYD");
    expect(node.querySelector("article")!.textContent).toContain("Visa extension");
    expect(node.querySelector("article svg.lucide-stamp")).not.toBeNull();
    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).toContain("3 extensions");
    expect(node.textContent).not.toContain("Quoted");
    await act(async () => root.unmount());
  });

  // Owner test 2026-10-04: waiting for the deposit, the card only said "Visa extension" and 10,000 GYD.
  it("shows the extensions count in the header while the deposit is awaited", async () => {
    const { node, root } = await render(visaOp({ status: "collecting_information", quotedSourceAmount: 10000 }));

    const header = node.querySelector("article button[aria-expanded]")!.textContent!;
    expect(header).toContain("10,000 GYD");
    expect(header).toContain("Visa extension");
    expect(header).toContain("2 extensions");
    await act(async () => root.unmount());
  });

  it("counts a single extension in the singular, and at least one", async () => {
    for (const amount of [5000, 2000, null]) {
      const { node, root } = await render(visaOp({ quotedSourceAmount: amount }));
      const summary = node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")!;
      expect(summary).toContain("1 extension");
      expect(summary).not.toContain("extensions");
      await act(async () => root.unmount());
      document.body.replaceChildren();
    }
  });

  it("has no beneficiary block, no add-beneficiary control and no missing-beneficiary warning", async () => {
    const { node, root } = await render(visaOp({ beneficiariesComplete: false }));

    expect(button(node, "Add beneficiary")).toBeNull();
    expect(node.textContent).not.toContain("Deliver to");
    expect(node.textContent).not.toContain("No beneficiaries recorded yet");
    expect(node.textContent).not.toContain("Awaiting beneficiary");
    await act(async () => root.unmount());
  });

  it("still offers complete and manual close, without the service picker", async () => {
    const { node, root } = await render(visaOp(), { role: "owner" });

    expect(buttonByText(node, "Complete transfer")).toBeDefined();
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.closing.closeButton).click());
    expect(node.querySelector('[data-testid="closing-stub"]')).not.toBeNull();
    await act(async () => root.unmount());
  });
});

describe("RemittanceOperationCard combo", () => {
  const comboOp = (overrides: Partial<RemittanceOperationRead> = {}) =>
    operation({
      serviceType: "combo",
      status: "ready_to_transfer",
      quotedSourceAmount: 55000,
      sourceCurrency: "GYD",
      beneficiaries: [
        beneficiary({
          id: "c1",
          beneficiaryType: "combo",
          name: "Ana Lopez",
          phone: "52345678",
          address: "Calle 1 #2, Habana",
          reference: "frente a la bodega",
          contactPhone: "53456789",
          amount: 25000,
          currency: "GYD",
          position: 1,
        }),
        beneficiary({
          id: "c2",
          beneficiaryType: "combo",
          name: "Luis Perez",
          phone: "62345678",
          address: "Calle 9, Matanzas",
          reference: "casa azul",
          contactPhone: "63456789",
          amount: 30000,
          currency: "GYD",
          position: 2,
        }),
      ],
      ...overrides,
    });

  it("shows the Combo label with its icon and the combo count, and no remesa quote line", async () => {
    const { node, root } = await render(comboOp(), {
      quote: { gyd: 55000, destinationAmount: 4000, destinationCurrency: "CUP", quotedAt: "2026-10-03T00:00:00Z" },
    });

    expect(node.querySelector("article")!.textContent).toContain("55,000 GYD");
    expect(node.querySelector("article")!.textContent).toContain("Combo");
    expect(node.querySelector("article svg.lucide-shopping-basket")).not.toBeNull();
    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).toContain("2 combos");
    expect(node.textContent).not.toContain("Quoted");
    await act(async () => root.unmount());
  });

  it("counts a single combo in the singular", async () => {
    const op = comboOp();
    const { node, root } = await render({ ...op, beneficiaries: [op.beneficiaries[0]!] });

    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).toContain("1 combo");
    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).not.toContain("combos");
    await act(async () => root.unmount());
  });

  it("shows every recipient field and its GYD amount, one set per recipient", async () => {
    const { node, root } = await render(comboOp());

    for (const text of [
      "Ana Lopez", "52345678", "Calle 1 #2, Habana", "frente a la bodega", "53456789", "25,000 GYD",
      "Luis Perez", "62345678", "Calle 9, Matanzas", "casa azul", "63456789", "30,000 GYD",
    ]) {
      expect(node.textContent, text).toContain(text);
    }
    expect(node.querySelectorAll('button[aria-label="Copy Name"]')).toHaveLength(2);
    expect(node.querySelectorAll('button[aria-label="Copy Phone"]')).toHaveLength(2);
    expect(node.querySelectorAll('button[aria-label="Copy Address"]')).toHaveLength(2);
    expect(node.querySelectorAll('button[aria-label="Copy Reference"]')).toHaveLength(2);
    expect(node.querySelectorAll('button[aria-label="Copy Contact phone"]')).toHaveLength(2);
    expect(button(node, "Copy Card")).toBeNull();
    expect(node.textContent).not.toContain("ID photo");
    await act(async () => root.unmount());
  });

  it("shows the amount of a single recipient too", async () => {
    const op = comboOp();
    const { node, root } = await render({ ...op, beneficiaries: [op.beneficiaries[0]!] });

    expect(node.textContent).toContain("25,000 GYD");
    await act(async () => root.unmount());
  });

  describe("edit and move a recipient", () => {
    const P = en.Inbox.operationsPanel;
    const click = (el: Element) => act(async () => el.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    const field = (node: Element, id: string) => node.querySelector<HTMLInputElement>(`#inline-${id}-c1`)!;
    async function openEdit(op = comboOp()) {
      const rendered = await render(op);
      await click(rendered.node.querySelectorAll(`button[aria-label="${P.editBeneficiary}"]`)[0]!);
      return rendered;
    }

    it("shows Edit on every combo recipient, and Move when another open combo exists", async () => {
      const { node, root } = await render(comboOp(), { otherOpenOperations: [{ id: "op-2", label: "x" }] });

      expect(node.querySelectorAll(`button[aria-label="${P.editBeneficiary}"]`)).toHaveLength(2);
      expect(node.querySelectorAll(`button[aria-label="${P.moveBeneficiary}"]`)).toHaveLength(2);
      await act(async () => root.unmount());
    });

    it("shows no Move without another open combo", async () => {
      const { node, root } = await render(comboOp());

      expect(button(node, P.editBeneficiary)).not.toBeNull();
      expect(button(node, P.moveBeneficiary)).toBeNull();
      await act(async () => root.unmount());
    });

    it("a single combo recipient is editable from the section header", async () => {
      const op = comboOp();
      op.beneficiaries = [op.beneficiaries[0]!];
      const { node, root } = await render(op);
      await click(button(node, P.editBeneficiary)!);

      expect(field(node, "amount").value).toBe("25000");
      await act(async () => root.unmount());
    });

    it("a viewer (canEdit false) gets no Edit", async () => {
      const { node, root } = await render(comboOp(), { canEdit: false });

      expect(button(node, P.editBeneficiary)).toBeNull();
      await act(async () => root.unmount());
    });

    it("pre-fills name, phone, address, reference, contact phone and amount", async () => {
      const { node, root } = await openEdit();

      expect(field(node, "name").value).toBe("Ana Lopez");
      expect(field(node, "phone").value).toBe("52345678");
      expect(field(node, "address").value).toBe("Calle 1 #2, Habana");
      expect(field(node, "reference").value).toBe("frente a la bodega");
      expect(field(node, "contact-phone").value).toBe("53456789");
      expect(field(node, "amount").value).toBe("25000");
      expect(node.querySelector(`#inline-card-c1`)).toBeNull();
      expect(node.textContent).toContain(P.comboMinimumHint);
      expect(node.textContent).toContain(P.comboProvinceHint);
      await act(async () => root.unmount());
    });

    it("sends only the changed keys", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root, onChanged } = await openEdit();
      await act(async () => setValue(field(node, "name"), "  Ana Maria Lopez "));
      await act(async () => setValue(field(node, "address"), "Calle 5, Matanzas"));
      await act(async () => setValue(field(node, "amount"), "27000"));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).toHaveBeenCalledWith("c1", {
        name: "Ana Maria Lopez",
        address: "Calle 5, Matanzas",
        amount: 27000,
      });
      expect(onChanged).toHaveBeenCalled();
      await act(async () => root.unmount());
    });

    it("clearing the contact phone sends null; clearing the reference sends null", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root } = await openEdit();
      await act(async () => setValue(field(node, "contact-phone"), ""));
      await act(async () => setValue(field(node, "reference"), ""));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).toHaveBeenCalledWith("c1", { contact_phone: null, reference: null });
      await act(async () => root.unmount());
    });

    it("a new contact phone is sent as digits only", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root } = await openEdit();
      await act(async () => setValue(field(node, "contact-phone"), "+53 5555 5555"));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).toHaveBeenCalledWith("c1", { contact_phone: "5355555555" });
      await act(async () => root.unmount());
    });

    it.each([
      ["name", "  ", P.cannotBeEmpty],
      ["phone", "123", P.invalidPhone],
      ["phone", "", P.cannotBeEmpty],
      ["contact-phone", "123", P.invalidPhone],
      ["amount", "0", P.invalidAmount],
      ["amount", "abc", P.invalidAmount],
    ])("blocks an invalid %s (%j) without calling the API", async (id, value, message) => {
      corregirBeneficiario.mockClear();
      const { node, root } = await openEdit();
      await act(async () => setValue(field(node, id), value));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector('[role="alert"]')!.textContent).toBe(message);
      await act(async () => root.unmount());
    });

    it("an amount below 25,000 only hints, it does not block", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root } = await openEdit();
      await act(async () => setValue(field(node, "amount"), "20000"));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).toHaveBeenCalledWith("c1", { amount: 20000 });
      await act(async () => root.unmount());
    });

    it("an address with no province still saves (hint only)", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root } = await openEdit();
      await act(async () => setValue(field(node, "address"), "Calle 5"));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).toHaveBeenCalledWith("c1", { address: "Calle 5" });
      await act(async () => root.unmount());
    });

    it("no changes closes the form without calling the API", async () => {
      corregirBeneficiario.mockClear();
      const { node, root } = await openEdit();
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(field(node, "name")).toBeNull();
      await act(async () => root.unmount());
    });

    it("shows the API error and stays open", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: false, status: 400, error: "amount must be greater than 0" });
      const { node, root } = await openEdit();
      await act(async () => setValue(field(node, "amount"), "30000"));
      await click(buttonByLabel(node, P.save));

      expect(node.querySelector('[role="alert"]')!.textContent).toBe("amount must be greater than 0");
      expect(field(node, "amount")).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("a remesa recipient's edit form has no combo-only fields and sends the same payload", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "52345678" })] }),
      );
      await click(button(node, P.editBeneficiary)!);

      expect(node.querySelector("#inline-address-ben-1")).toBeNull();
      expect(node.querySelector("#inline-reference-ben-1")).toBeNull();
      expect(node.querySelector("#inline-contact-phone-ben-1")).toBeNull();
      expect(node.textContent).not.toContain(P.comboMinimumHint);
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-phone-ben-1")!, "53456789"));
      await click(buttonByLabel(node, P.save));

      expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { phone: "53456789" });
      await act(async () => root.unmount());
    });
  });

  it.each([
    ["owner", true],
    ["admin", true],
    ["agent", false],
    ["viewer", false],
    [null, false],
  ] as const)("the cost field for role %s is shown: %s", async (role, shown) => {
    const { node, root } = await render(comboOp({ comboCostoGyd: 18000 }), { role });

    const stub = node.querySelector('[data-testid="combo-cost-stub"]');
    expect(stub !== null).toBe(shown);
    if (shown) {
      expect(stub!.getAttribute("data-cost")).toBe("18000");
      expect(stub!.getAttribute("data-completed")).toBe("false");
    }
    await act(async () => root.unmount());
  });

  it("a completed (history) combo shows the cost field to the cost role passed in, flagged completed", async () => {
    const { RemittanceOperationCard } = await import("./remittance-operation-card");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () =>
      root.render(
        <RemittanceOperationCard
          operation={comboOp({ status: "completed", isHistory: true })}
          canEdit={false}
          role={null}
          costRole="owner"
          otherOpenOperations={[]}
          onChanged={vi.fn()}
          expanded
          onToggle={vi.fn()}
          conversationId="conv-1"
        />,
      ),
    );

    expect(node.querySelector('[data-testid="combo-cost-stub"]')!.getAttribute("data-completed")).toBe("true");
    await act(async () => root.unmount());
  });

  it("no cost field on a remesa or a recharge", async () => {
    const { node, root } = await render(operation(), { role: "owner" });

    expect(node.querySelector('[data-testid="combo-cost-stub"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("hands the service type to the add control", async () => {
    const { node, root } = await render(comboOp());
    await act(async () => (button(node, "Add beneficiary") as HTMLButtonElement).click());

    expect(node.querySelector('[data-testid="add-beneficiary-stub"]')!.getAttribute("data-service-type")).toBe("combo");
    await act(async () => root.unmount());
  });
});

describe("RemittanceOperationCard recharge", () => {
  const rechargeOp = () =>
    operation({
      serviceType: "recarga",
      status: "ready_to_transfer",
      quotedSourceAmount: 10400,
      quotedDestinationAmount: 99,
      deliveryMethod: "recarga",
      beneficiaries: [
        beneficiary({ id: "r1", beneficiaryType: "recarga", phone: "52345678", position: 1 }),
        beneficiary({ id: "r2", beneficiaryType: "recarga", phone: "63456789", position: 2 }),
      ],
    });

  it("shows the Recharge label and icon, the deposit in GYD, and the recharge count", async () => {
    const { node, root } = await render(rechargeOp(), { quote: { gyd: 10400, destinationAmount: 4000, destinationCurrency: "CUP", quotedAt: "2026-10-03T00:00:00Z" } });

    expect(node.textContent).toContain("10,400 GYD");
    expect(node.textContent).toContain("Recharge");
    expect(node.querySelector("article svg.lucide-smartphone")).not.toBeNull();
    const summary = node.querySelector('[data-testid="deposit-review-stub"]')!;
    expect(summary.getAttribute("data-summary-amount")).toContain("2 recharges");
    await act(async () => root.unmount());
  });

  it("shows one copy chip per number and no card, amount or remesa-only quote line", async () => {
    const { node, root } = await render(rechargeOp(), { quote: { gyd: 10400, destinationAmount: 4000, destinationCurrency: "CUP", quotedAt: "2026-10-03T00:00:00Z" } });

    expect(button(node, "Copy Phone")).not.toBeNull();
    expect(node.querySelectorAll('button[aria-label="Copy Phone"]')).toHaveLength(2);
    expect(node.textContent).toContain("52345678");
    expect(node.textContent).toContain("63456789");
    expect(button(node, "Copy Card")).toBeNull();
    expect(node.textContent).not.toContain("Quoted");
    expect(node.textContent).not.toContain("CUP");
    expect(node.textContent).not.toContain("99");
    await act(async () => root.unmount());
  });

  it("hands the service type to the add control", async () => {
    const { node, root } = await render(rechargeOp());
    await act(async () => (button(node, "Add beneficiary") as HTMLButtonElement).click());

    expect(node.querySelector('[data-testid="add-beneficiary-stub"]')!.getAttribute("data-service-type")).toBe("recarga");
    await act(async () => root.unmount());
  });

  it("editing a number shows only the phone field", async () => {
    const { node, root } = await render(rechargeOp());
    await act(async () => (node.querySelectorAll('button[aria-label="Edit"]')[0] as HTMLButtonElement).click());

    expect(node.querySelector('input[aria-label="Phone"]')).not.toBeNull();
    expect(node.querySelector('input[aria-label="Card"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("completing a recharge passes one proof slot per number, none Zelle", async () => {
    const { node, root } = await render(rechargeOp());
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.completeTransfer.button).click());

    const props = CompleteTransferContainer.mock.calls.at(-1)![0] as unknown as { isZelle: boolean; beneficiaries: { id: string; isZelle: boolean }[] };
    expect(props.isZelle).toBe(false);
    expect(props.beneficiaries).toEqual([{ id: "r1", isZelle: false }, { id: "r2", isZelle: false }]);
    await act(async () => root.unmount());
  });

  it("a remesa card is unchanged: quote line, no Recharge label", async () => {
    const { node, root } = await render(
      operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", amount: 100, currency: "CUP" })] }),
      { quote: { gyd: 10400, destinationAmount: 4000, destinationCurrency: "CUP", quotedAt: "2026-10-03T00:00:00Z" } },
    );

    expect(node.textContent).toContain("Quoted: 10,400 GYD → 4,000 CUP");
    expect(node.textContent).not.toContain("Recharge");
    expect(node.querySelector("article svg.lucide-smartphone")).toBeNull();
    await act(async () => root.unmount());
  });
});

describe("RemittanceOperationCard mobile balance (saldo)", () => {
  const saldoOp = (overrides: Partial<RemittanceOperationRead> = {}) =>
    operation({
      serviceType: "saldo",
      status: "ready_to_transfer",
      quotedSourceAmount: 5000,
      quotedDestinationAmount: 99,
      deliveryMethod: null,
      beneficiaries: [beneficiary({ id: "s1", beneficiaryType: "recarga", phone: "52345678", position: 1 })],
      ...overrides,
    });
  const quote: ConversationQuoteRead = { gyd: 5000, destinationAmount: 4000, destinationCurrency: "CUP", quotedAt: "2026-10-03T00:00:00Z" };

  it("shows the Mobile balance label with its own icon, the package count and the saldo (packages x 360)", async () => {
    const { node, root } = await render(saldoOp(), { quote });

    const header = node.querySelector("article button[aria-expanded]")!.textContent!;
    expect(header).toContain("5,000 GYD");
    expect(header).toContain("Mobile balance");
    expect(header).toContain("5 packages · 1,800 SM");
    expect(node.querySelector("article svg.lucide-coins")).not.toBeNull();
    expect(node.querySelector("article svg.lucide-smartphone")).toBeNull();
    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).toContain("5 packages · 1,800 SM");
    await act(async () => root.unmount());
  });

  it("counts a single package in the singular", async () => {
    const { node, root } = await render(saldoOp({ quotedSourceAmount: 1000 }), { quote });

    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).toContain("1 package · 360 SM");
    await act(async () => root.unmount());
  });

  it("names no count when the deposit is not a whole number of packages (no rounding)", async () => {
    const { node, root } = await render(saldoOp({ quotedSourceAmount: 5500 }), { quote });

    const header = node.querySelector("article button[aria-expanded]")!.textContent!;
    expect(header).toContain("Mobile balance");
    expect(header).not.toContain("package");
    expect(node.querySelector('[data-testid="deposit-review-stub"]')!.getAttribute("data-summary-amount")).toBe("null");
    await act(async () => root.unmount());
  });

  it("hides the quote line and shows its one phone as a copy chip, no card and no amount", async () => {
    const { node, root } = await render(saldoOp(), { quote });

    expect(node.textContent).not.toContain("Quoted");
    expect(node.textContent).not.toContain("99");
    expect(node.textContent).toContain("52345678");
    expect(node.querySelectorAll('button[aria-label="Copy Phone"]')).toHaveLength(1);
    expect(button(node, "Copy Card")).toBeNull();
    await act(async () => root.unmount());
  });

  it("takes a single number: the add control is offered only while it has none, and gets the service type", async () => {
    const withNumber = await render(saldoOp());
    expect(button(withNumber.node, "Add beneficiary")).toBeNull();
    await act(async () => withNumber.root.unmount());
    document.body.replaceChildren();

    const empty = await render(saldoOp({ beneficiaries: [], beneficiariesComplete: false }));
    await act(async () => (button(empty.node, "Add beneficiary") as HTMLButtonElement).click());
    expect(empty.node.querySelector('[data-testid="add-beneficiary-stub"]')!.getAttribute("data-service-type")).toBe("saldo");
    await act(async () => empty.root.unmount());
  });

  it("editing its number shows only the phone field", async () => {
    const { node, root } = await render(saldoOp());
    await act(async () => (node.querySelectorAll('button[aria-label="Edit"]')[0] as HTMLButtonElement).click());

    expect(node.querySelector('input[aria-label="Phone"]')).not.toBeNull();
    expect(node.querySelector('input[aria-label="Card"]')).toBeNull();
    await act(async () => root.unmount());
  });
});

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

  describe("header destination label", () => {
    it("reads Mixed when the split spans more than one destination unit", async () => {
      const { node, root } = await render(
        operation({
          deliveryMethod: "cuban_card",
          destinationCurrency: "CUP",
          beneficiaries: [
            beneficiary({ id: "b1", beneficiaryType: "cuban_card", amount: 120000, currency: "CUP" }),
            beneficiary({ id: "b2", beneficiaryType: "zelle", amount: 200, currency: "USD" }),
            beneficiary({ id: "b3", beneficiaryType: "clasica", amount: 40, currency: "USD" }),
          ],
        }),
      );

      expect(node.textContent).toContain(en.Inbox.operationsPanel.mixedDestination);
      await act(async () => root.unmount());
    });

    it("keeps the single unit when every beneficiary lands on the same one", async () => {
      const { node, root } = await render(
        operation({
          deliveryMethod: "cuban_card",
          destinationCurrency: "CUP",
          beneficiaries: [
            beneficiary({ id: "b1", beneficiaryType: "cuban_card", amount: 135000, currency: "CUP" }),
            beneficiary({ id: "b2", beneficiaryType: "cuban_card", amount: 90000, currency: "CUP" }),
          ],
        }),
      );

      expect(node.textContent).toContain("CUP");
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.mixedDestination);
      await act(async () => root.unmount());
    });

    it("keeps the operation-level label when there are no beneficiaries yet", async () => {
      const { node, root } = await render(
        operation({ deliveryMethod: "cuban_card", destinationCurrency: "CUP", beneficiaries: [] }),
      );

      expect(node.textContent).toContain("CUP");
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.mixedDestination);
      await act(async () => root.unmount());
    });
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

  describe("cash (efectivo_usd) beneficiary", () => {
    const cashOperation = (b: Partial<RemittanceBeneficiaryRead> = {}) =>
      operation({
        destinationCurrency: "USD",
        quotedDestinationAmount: 100,
        beneficiaries: [
          beneficiary({
            beneficiaryType: "efectivo_usd",
            phone: "5926001111",
            address: "12 Main St, Georgetown",
            idPhotoWamid: "wamid.ABC",
            idPhotoUrl: "https://cdn.example.invalid/id.jpg",
            ...b,
          }),
        ],
      });

    it("shows the phone, address, an ID link opening in a new tab, the USD cash amount and no card line", async () => {
      const { node, root } = await render(cashOperation());

      expect(node.textContent).toContain(en.Inbox.operationsPanel.beneficiaryType.efectivo_usd);
      expect(button(node, "Copy Phone")?.textContent).toContain("5926001111");
      expect(node.textContent).toContain("12 Main St, Georgetown");
      const link = Array.from(node.querySelectorAll("a")).find(
        (a) => a.textContent === en.Inbox.operationsPanel.viewIdPhoto,
      ) as HTMLAnchorElement;
      expect(link.getAttribute("href")).toBe("https://cdn.example.invalid/id.jpg");
      expect(link.getAttribute("target")).toBe("_blank");
      expect(link.getAttribute("rel")).toContain("noopener");
      expect(button(node, "Copy Card")).toBeNull();
      const summary = node.querySelector('[data-testid="deposit-review-stub"]')!;
      expect(summary.getAttribute("data-summary-amount")).toContain("100 USD cash");
      await act(async () => root.unmount());
    });

    it("shows the cash recipient's name as a copy chip when it is stored", async () => {
      const { node, root } = await render(cashOperation({ name: "Maria Lopez" }));

      expect(button(node, "Copy Name")?.textContent).toContain("Maria Lopez");
      await act(async () => root.unmount());
    });

    it("shows no name line (and no 'unavailable' notice) when the cash recipient has no name", async () => {
      const { node, root } = await render(cashOperation({ name: null }));

      expect(button(node, "Copy Name")).toBeNull();
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.beneficiaryNameUnavailable);
      await act(async () => root.unmount());
    });

    it("says the ID photo is missing when there is no URL", async () => {
      const { node, root } = await render(cashOperation({ idPhotoUrl: null, idPhotoWamid: null }));

      expect(Array.from(node.querySelectorAll("a")).some((a) => a.textContent === en.Inbox.operationsPanel.viewIdPhoto)).toBe(false);
      expect(node.textContent).toContain(en.Inbox.operationsPanel.idPhotoMissing);
      await act(async () => root.unmount());
    });

    it("a cuban_card beneficiary shows no address or ID photo lines", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5350001111" })] }),
      );

      expect(button(node, "Copy Card")).not.toBeNull();
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.idPhotoMissing);
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.viewIdPhoto);
      await act(async () => root.unmount());
    });
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

    it("labels Clásica and Tropical amounts by service, not by currency", async () => {
      for (const [type, label] of [["clasica", "Clásica"], ["tropical", "Tropical"]] as const) {
        const { node, root } = await render(
          operation({ beneficiaries: [beneficiary({ beneficiaryType: type, amount: 40, currency: "USD" })] }),
        );

        expect(summaryAmountFromStub(node)).toEqual({ kind: "amount", display: `40 ${label}` });
        await act(async () => root.unmount());
      }
    });

    it("labels a Clásica amount by service when the operation has no beneficiaries yet", async () => {
      const { node, root } = await render(
        operation({ beneficiaries: [], deliveryMethod: "clasica", quotedDestinationAmount: 40, destinationCurrency: "USD" }),
      );

      expect(summaryAmountFromStub(node)).toEqual({ kind: "amount", display: "40 Clásica" });
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
    const T = en.Inbox.operationsPanel.completeTransfer;

    function readyOperation(overrides: Partial<RemittanceOperationRead> = {}) {
      return operation({ id: "op-1", status: "ready_to_transfer", ...overrides });
    }

    function findCompleteButton(node: Element): HTMLButtonElement | undefined {
      return Array.from(node.querySelectorAll("button")).find(
        (b) => b.textContent?.trim() === T.button,
      ) as HTMLButtonElement | undefined;
    }

    it("is absent when the status is not ready_to_transfer", async () => {
      const { node, root } = await render(operation({ status: "deposit_verification" }));
      expect(node.textContent).not.toContain(T.button);
      await act(async () => root.unmount());
    });

    it("is absent when the card is not editable", async () => {
      const { node, root } = await render(readyOperation(), { canEdit: false });
      expect(node.textContent).not.toContain(T.button);
      await act(async () => root.unmount());
    });

    it("renders full-width when ready_to_transfer and editable", async () => {
      const { node, root } = await render(readyOperation(), { canEdit: true });
      expect(findCompleteButton(node)).not.toBeUndefined();
      await act(async () => root.unmount());
    });

    it("clicking it opens the complete-transfer section, passing operationId/conversationId/isZelle, hiding the button", async () => {
      const { node, root } = await render(readyOperation({ deliveryMethod: "zelle" }), {
        conversationId: "conv-42",
      });

      const button = findCompleteButton(node)!;
      await act(async () => button.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(node.querySelector('[data-testid="complete-transfer-stub"]')).not.toBeNull();
      expect(findCompleteButton(node)).toBeUndefined();
      expect(CompleteTransferContainer).toHaveBeenCalledWith(
        expect.objectContaining({ operationId: "op-1", conversationId: "conv-42", isZelle: true }),
      );
      await act(async () => root.unmount());
    });

    it("passes isZelle:false for a non-Zelle operation", async () => {
      const { node, root } = await render(readyOperation({ deliveryMethod: "cuban_card" }));

      await act(async () =>
        findCompleteButton(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(CompleteTransferContainer).toHaveBeenCalledWith(
        expect.objectContaining({ isZelle: false }),
      );
      await act(async () => root.unmount());
    });

    describe("isZelle from beneficiaries, not deliveryMethod or count", () => {
      async function isZellePassed(op: RemittanceOperationRead): Promise<boolean> {
        const { node } = await render(op);
        await act(async () =>
          findCompleteButton(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
        );
        const call = CompleteTransferContainer.mock.calls.at(-1)![0] as unknown as { isZelle: boolean };
        return call.isZelle;
      }

      it("shows the caption for a stale/null deliveryMethod with a single Zelle beneficiary", async () => {
        const op = readyOperation({
          deliveryMethod: null,
          beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "Yaima" })],
        });
        expect(await isZellePassed(op)).toBe(true);
      });

      it("shows the caption for 2 Zelle beneficiaries (delivery_method stale/null)", async () => {
        const op = readyOperation({
          deliveryMethod: "cuban_card",
          beneficiaries: [
            beneficiary({ id: "b1", beneficiaryType: "zelle", name: "Yaima" }),
            beneficiary({ id: "b2", beneficiaryType: "zelle", name: "Maria" }),
          ],
        });
        expect(await isZellePassed(op)).toBe(true);
      });

      it("shows the caption for a mixed reparto (cuban_card + zelle)", async () => {
        const op = readyOperation({
          deliveryMethod: null,
          beneficiaries: [
            beneficiary({ id: "b1", beneficiaryType: "cuban_card" }),
            beneficiary({ id: "b2", beneficiaryType: "zelle", name: "Maria" }),
          ],
        });
        expect(await isZellePassed(op)).toBe(true);
      });

      it("hides the caption for a pure Cuban-card reparto, even with a stale zelle delivery_method", async () => {
        const op = readyOperation({
          deliveryMethod: "zelle",
          beneficiaries: [
            beneficiary({ id: "b1", beneficiaryType: "cuban_card" }),
            beneficiary({ id: "b2", beneficiaryType: "cuban_card" }),
          ],
        });
        expect(await isZellePassed(op)).toBe(false);
      });

      it("shows the caption for the legacy shape: no beneficiaries yet, delivery_method 'zelle'", async () => {
        const op = readyOperation({ deliveryMethod: "zelle", beneficiaries: [] });
        expect(await isZellePassed(op)).toBe(true);
      });
    });

    it("passes the current beneficiaries as {id, isZelle} pairs, in order", async () => {
      const op = readyOperation({
        beneficiaries: [
          beneficiary({ id: "b1", beneficiaryType: "zelle", name: "Ana" }),
          beneficiary({ id: "b2", beneficiaryType: "cuban_card" }),
        ],
      });
      const { node } = await render(op);
      await act(async () =>
        findCompleteButton(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(CompleteTransferContainer).toHaveBeenCalledWith(
        expect.objectContaining({
          beneficiaries: [
            { id: "b1", isZelle: true },
            { id: "b2", isZelle: false },
          ],
        }),
      );
    });

    it("onCancel from the section restores the button", async () => {
      const { node, root } = await render(readyOperation());

      await act(async () =>
        findCompleteButton(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );
      await act(async () =>
        node
          .querySelector('[data-testid="complete-transfer-cancel"]')!
          .dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(findCompleteButton(node)).not.toBeUndefined();
      expect(node.querySelector('[data-testid="complete-transfer-stub"]')).toBeNull();
      await act(async () => root.unmount());
    });

    it("onDone from the section refetches (onChanged) and restores the button", async () => {
      const onChanged = vi.fn();
      const { node, root } = await render(readyOperation(), { onChanged });

      await act(async () =>
        findCompleteButton(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );
      await act(async () =>
        node
          .querySelector('[data-testid="complete-transfer-done"]')!
          .dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(onChanged).toHaveBeenCalledTimes(1);
      expect(findCompleteButton(node)).not.toBeUndefined();
      await act(async () => root.unmount());
    });
  });

  describe("Add beneficiary button", () => {
    const ADD_LABEL = en.Inbox.operationsPanel.addBeneficiary;

    it("is absent when the card is not editable", async () => {
      const { node, root } = await render(operation(), { canEdit: false });
      expect(button(node, ADD_LABEL)).toBeNull();
      await act(async () => root.unmount());
    });

    it("is absent when the operation status is terminal", async () => {
      const { node, root } = await render(operation({ status: "completed" }));
      expect(button(node, ADD_LABEL)).toBeNull();
      await act(async () => root.unmount());
    });

    it("is absent for a history row even when canEdit is true", async () => {
      const { node, root } = await render(operation({ isHistory: true, status: "completed" }));
      expect(button(node, ADD_LABEL)).toBeNull();
      await act(async () => root.unmount());
    });

    it("renders next to the Deliver to heading when editable", async () => {
      const { node, root } = await render(operation());
      expect(button(node, ADD_LABEL)).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("passes the operation's quote to the add control only when it has no recipient yet", async () => {
      const first = await render(operation({ id: "op-q", deliveryMethod: "zelle", destinationCurrency: "USD", quotedDestinationAmount: 100 }));
      await act(async () => button(first.node, ADD_LABEL)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(BeneficiaryAddControl).toHaveBeenLastCalledWith(expect.objectContaining({ quote: { amount: 100, currency: "USD" } }));
      await act(async () => first.root.unmount());

      const second = await render(
        operation({
          id: "op-q2", deliveryMethod: "zelle", destinationCurrency: "USD", quotedDestinationAmount: 100,
          beneficiaries: [beneficiary({ beneficiaryType: "zelle", name: "A", zelleAccount: "a@b.co" })],
        }),
      );
      await act(async () => button(second.node, ADD_LABEL)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(BeneficiaryAddControl).toHaveBeenLastCalledWith(expect.objectContaining({ quote: null }));
      await act(async () => second.root.unmount());
    });

    it("clicking it opens the add-beneficiary control, passing operationId, and hides the button", async () => {
      const { node, root } = await render(operation({ id: "op-9" }));

      await act(async () =>
        button(node, ADD_LABEL)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(node.querySelector('[data-testid="add-beneficiary-stub"]')).not.toBeNull();
      expect(button(node, ADD_LABEL)).toBeNull();
      expect(BeneficiaryAddControl).toHaveBeenCalledWith(
        expect.objectContaining({ operationId: "op-9" }),
      );
      await act(async () => root.unmount());
    });

    it("passes the operation's current service so the form shows that service's fields", async () => {
      const cases: Array<[Partial<RemittanceOperationRead>, string]> = [
        [{ deliveryMethod: "efectivo_usd", beneficiaries: [] }, "efectivo_usd"],
        [{ deliveryMethod: "zelle", beneficiaries: [] }, "zelle"],
        [{ deliveryMethod: null, beneficiaries: [] }, ""],
      ];
      for (const [overrides, expected] of cases) {
        const { node, root } = await render(operation(overrides));
        await act(async () => button(node, ADD_LABEL)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
        expect(node.querySelector('[data-testid="add-beneficiary-stub"]')!.getAttribute("data-service")).toBe(expected);
        await act(async () => root.unmount());
      }
    });

    it("hides the add button when a cash operation already has its one recipient", async () => {
      const { node, root } = await render(
        operation({
          deliveryMethod: "efectivo_usd",
          beneficiaries: [beneficiary({ beneficiaryType: "efectivo_usd", cardNumber: null, address: "Calle 1", phone: "52123456" })],
        }),
      );
      expect(button(node, ADD_LABEL)).toBeNull();
      await act(async () => root.unmount());
    });

    it("onCancel from the control restores the button", async () => {
      const { node, root } = await render(operation());

      await act(async () =>
        button(node, ADD_LABEL)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );
      await act(async () =>
        node
          .querySelector('[data-testid="add-beneficiary-cancel"]')!
          .dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(button(node, ADD_LABEL)).not.toBeNull();
      expect(node.querySelector('[data-testid="add-beneficiary-stub"]')).toBeNull();
      await act(async () => root.unmount());
    });

    it("onDone from the control calls onChanged and restores the button", async () => {
      const onChanged = vi.fn();
      const { node, root } = await render(operation(), { onChanged });

      await act(async () =>
        button(node, ADD_LABEL)!.dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );
      await act(async () =>
        node
          .querySelector('[data-testid="add-beneficiary-done"]')!
          .dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );

      expect(onChanged).toHaveBeenCalledTimes(1);
      expect(button(node, ADD_LABEL)).not.toBeNull();
      await act(async () => root.unmount());
    });
  });

  describe("Beneficiary edit form follows the recipient type (T2e)", () => {
    async function openEdit(b: Partial<RemittanceBeneficiaryRead>, op: Partial<RemittanceOperationRead> = {}) {
      const rendered = await render(operation({ beneficiaries: [beneficiary({ id: "ben-1", ...b })], ...op }));
      await act(async () =>
        button(rendered.node, en.Inbox.operationsPanel.editBeneficiary)!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        ),
      );
      return rendered;
    }
    const ids = (node: HTMLElement) =>
      ["name", "card", "phone", "zelle-account", "address"].filter((k) => node.querySelector(`#inline-${k}-ben-1`) !== null);
    async function save(node: HTMLElement) {
      await act(async () =>
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
      );
    }

    it.each([
      ["efectivo_usd", ["name", "phone", "address"]],
      ["zelle", ["name", "zelle-account"]],
      ["cuban_card", ["card", "phone"]],
      ["clasica", ["card", "phone"]],
      ["tropical", ["card", "phone"]],
      ["recarga", ["phone"]],
    ])("%s offers exactly its own fields", async (type, expected) => {
      const { node, root } = await openEdit({ beneficiaryType: type as RemittanceBeneficiaryRead["beneficiaryType"] });
      expect(ids(node)).toEqual(expected);
      await act(async () => root.unmount());
    });

    it("cash: shows the ID photo note and prefilled name, phone and address", async () => {
      const { node, root } = await openEdit({
        beneficiaryType: "efectivo_usd", name: "Maria", phone: "5926001111", address: "12 Main St",
      });
      expect(node.querySelector<HTMLInputElement>("#inline-name-ben-1")!.value).toBe("Maria");
      expect(node.querySelector<HTMLInputElement>("#inline-phone-ben-1")!.value).toBe("5926001111");
      expect(node.querySelector<HTMLInputElement>("#inline-address-ben-1")!.value).toBe("12 Main St");
      expect(node.textContent).toContain(en.Inbox.operationsPanel.cashIdPhotoHint);
      await act(async () => root.unmount());
    });

    it("cash: saving sends only the changed name / phone / address keys", async () => {
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root } = await openEdit({
        beneficiaryType: "efectivo_usd", name: "Maria", phone: "5926001111", address: "12 Main St",
      });
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-name-ben-1")!, "Maria L"));
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-phone-ben-1")!, "592 600 2222"));
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-address-ben-1")!, "14 Water St"));
      await save(node);
      expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: "Maria L", phone: "5926002222", address: "14 Water St" });
      await act(async () => root.unmount());
    });

    it("cash: the optional name can be cleared (null) but address and phone cannot be emptied", async () => {
      corregirBeneficiario.mockClear();
      corregirBeneficiario.mockResolvedValue({ ok: true, id: "n1" });
      const { node, root } = await openEdit({
        beneficiaryType: "efectivo_usd", name: "Maria", phone: "5926001111", address: "12 Main St",
      });
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-address-ben-1")!, ""));
      await save(node);
      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector('[role="alert"]')?.textContent).toBe(en.Inbox.operationsPanel.cannotBeEmpty);
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-address-ben-1")!, "12 Main St"));
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-name-ben-1")!, ""));
      await save(node);
      expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: null });
      await act(async () => root.unmount());
    });

    it("cash: a phone that is not 8 to 15 digits is refused before the request", async () => {
      corregirBeneficiario.mockClear();
      const { node, root } = await openEdit({ beneficiaryType: "efectivo_usd", phone: "5926001111", address: "x" });
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#inline-phone-ben-1")!, "123"));
      await save(node);
      expect(corregirBeneficiario).not.toHaveBeenCalled();
      expect(node.querySelector('[role="alert"]')?.textContent).toBe(en.Inbox.operationsPanel.invalidPhone);
      await act(async () => root.unmount());
    });

    it("the other types show no address and no ID photo note", async () => {
      const { node, root } = await openEdit({ beneficiaryType: "cuban_card", cardNumber: "9205123412349412" });
      expect(node.querySelector("#inline-address-ben-1")).toBeNull();
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.cashIdPhotoHint);
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
      // The first field takes focus so it is obvious the data is now editable.
      expect(document.activeElement).toBe(nameInput);
      // Minimalist edit look: a bottom rule on a transparent row, not a filled, fully bordered box.
      expect(nameInput.parentElement!.className).toContain("border-b");
      expect(nameInput.parentElement!.className).not.toContain("bg-muted");
      expect(nameInput.parentElement!.className).not.toContain("rounded-md");
      expect(button(node, "Copy Name")).toBeNull();
      expect(button(node, "Copy Zelle account")).toBeNull();
      expect(node.querySelector("select")).toBeNull();
      expect(buttonByLabel(node, en.Inbox.operationsPanel.save)).not.toBeUndefined();
      expect(buttonByLabel(node, en.Inbox.operationsPanel.cancel)).not.toBeUndefined();

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
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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
        buttonByLabel(node, en.Inbox.operationsPanel.cancel).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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
        buttonByLabel(node, en.Inbox.operationsPanel.save).dispatchEvent(new MouseEvent("click", { bubbles: true })),
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

  describe("effective status (migration 102 readiness)", () => {
    it("shows awaiting_beneficiary and hides Complete transfer when ready_to_transfer but beneficiaries are incomplete", async () => {
      const { node, root } = await render(
        operation({ status: "ready_to_transfer", beneficiariesComplete: false }),
        { canEdit: true },
      );

      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.awaiting_beneficiary);
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.completeTransfer.button);
      await act(async () => root.unmount());
    });

    it("shows awaiting_deposit when collecting_information but beneficiaries are complete", async () => {
      const { node, root } = await render(
        operation({ status: "collecting_information", beneficiariesComplete: true }),
      );

      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.awaiting_deposit);
      await act(async () => root.unmount());
    });

    it("leaves deposit_verification's label unchanged regardless of beneficiariesComplete", async () => {
      const { node, root } = await render(
        operation({ status: "deposit_verification", beneficiariesComplete: false }),
      );

      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.deposit_verification);
      await act(async () => root.unmount());
    });
  });

  describe("History (completed) card", () => {
    function historyOperation(overrides: Partial<RemittanceOperationRead> = {}) {
      return operation({
        status: "completed",
        isHistory: true,
        beneficiariesComplete: true,
        completedAt: "2026-09-14T18:30:00Z",
        deliveredAt: "2026-09-14T18:30:00Z",
        deliveryMode: "proof_sent",
        beneficiaries: [beneficiary({ cardNumber: "9205123412349412", phone: "5355551111" })],
        ...overrides,
      });
    }

    it("shows the status chip as Completed", async () => {
      const { node, root } = await render(historyOperation());

      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.completed);
      await act(async () => root.unmount());
    });

    it("hides the edit-operation pencil even when canEdit is true", async () => {
      const { node, root } = await render(historyOperation(), { canEdit: true });

      expect(button(node, en.Inbox.operationsPanel.editOperation)).toBeNull();
      await act(async () => root.unmount());
    });

    it("hides beneficiary edit/move pencils even when canEdit is true and other operations exist", async () => {
      const { node, root } = await render(historyOperation(), {
        canEdit: true,
        otherOpenOperations: [{ id: "op-2", label: "x" }],
      });

      expect(button(node, en.Inbox.operationsPanel.editBeneficiary)).toBeNull();
      expect(button(node, en.Inbox.operationsPanel.moveBeneficiary)).toBeNull();
      await act(async () => root.unmount());
    });

    it("never shows the Complete transfer button, even when canEdit is true", async () => {
      const { node, root } = await render(historyOperation(), { canEdit: true });

      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.completeTransfer.button);
      await act(async () => root.unmount());
    });

    it("passes canEdit:false and role:null to the deposit review block regardless of the card's own canEdit/role", async () => {
      const { node, root } = await render(historyOperation(), { canEdit: true, role: "owner" });

      const stub = node.querySelector('[data-testid="deposit-review-stub"]')!;
      expect(stub.getAttribute("data-can-edit")).toBe("false");
      expect(stub.getAttribute("data-role")).toBe("");
      await act(async () => root.unmount());
    });

    it("still lets a beneficiary chip be copied", async () => {
      const writeText = vi.fn().mockResolvedValue(undefined);
      stubClipboard(writeText);
      const { node, root } = await render(historyOperation());

      await act(async () => button(node, "Copy Card")!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(writeText).toHaveBeenCalledWith("9205123412349412");
      await act(async () => root.unmount());
    });

    it("shows a muted 'Completed <date>' line with the with-screenshot suffix for proof_sent", async () => {
      const { node, root } = await render(historyOperation({ deliveryMode: "proof_sent" }));

      expect(node.textContent).toContain("2026");
      expect(node.textContent).toContain("with screenshot");
      // The status line already says "Completed"; the date line must not repeat it.
      expect(node.textContent!.match(/Completed/g)?.length).toBe(1);
      await act(async () => root.unmount());
    });

    it("shows the without-screenshot suffix for no_proof", async () => {
      const { node, root } = await render(historyOperation({ deliveryMode: "no_proof" }));

      expect(node.textContent).toContain("without screenshot");
      await act(async () => root.unmount());
    });

    it("shows the window-closed suffix for skip_proof", async () => {
      const { node, root } = await render(historyOperation({ deliveryMode: "skip_proof" }));

      expect(node.textContent).toContain("window closed, no screenshot");
      await act(async () => root.unmount());
    });
  });
});

describe("RemittanceOperationCard — the bot's quote", () => {
  const QUOTE: ConversationQuoteRead = {
    gyd: 5000,
    destinationAmount: 15000,
    destinationCurrency: "CUP",
    quotedAt: "2026-10-02T10:00:00Z",
  };

  it("shows what the bot quoted, even collapsed", async () => {
    const { node, root } = await render(operation({ quotedSourceAmount: null }), { quote: QUOTE, expanded: false });

    expect(node.textContent).toContain("Quoted: 5,000 GYD → 15,000 CUP");
    await act(async () => root.unmount());
  });

  it("formats a USD destination", async () => {
    const { node, root } = await render(operation(), {
      quote: { ...QUOTE, gyd: 26000, destinationAmount: 100, destinationCurrency: "USD" },
    });

    expect(node.textContent).toContain("Quoted: 26,000 GYD → 100 USD");
    await act(async () => root.unmount());
  });

  it("shows only the GYD amount when the quote has no destination", async () => {
    const { node, root } = await render(operation(), {
      quote: { ...QUOTE, destinationAmount: null, destinationCurrency: null },
    });

    expect(node.textContent).toContain("Quoted: 5,000 GYD");
    expect(node.textContent).not.toContain("Quoted: 5,000 GYD →");
    await act(async () => root.unmount());
  });

  it("shows nothing without a quote", async () => {
    const { node, root } = await render(operation(), { quote: null });

    expect(node.textContent).not.toContain("Quoted:");
    await act(async () => root.unmount());
  });

  it("never shows it on a history operation", async () => {
    const { node, root } = await render(operation({ isHistory: true, status: "completed" }), { quote: QUOTE });

    expect(node.textContent).not.toContain("Quoted:");
    await act(async () => root.unmount());
  });
});

describe("RemittanceOperationCard closing actions", () => {
  const copy = en.Inbox.operationsPanel.closing;
  const deleteButton = (node: Element) => button(node, copy.deleteButton);
  const closeButton = (node: Element) => button(node, copy.closeButton) ?? buttonByText(node, copy.closeButton);

  it.each(["owner", "admin"] as const)("%s sees the trash button on an open operation", async (role) => {
    const { node, root } = await render(operation({ status: "deposit_verification" }), { role });

    expect(deleteButton(node)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it.each(["agent", "viewer", null] as const)("%s never sees either closing button", async (role) => {
    const { node, root } = await render(operation({ status: "deposit_verification" }), { role });
    const second = await render(operation({ status: "ready_to_transfer" }), { role });

    expect(deleteButton(node)).toBeNull();
    expect(closeButton(second.node)).toBeFalsy();
    expect(deleteButton(second.node)).toBeNull();
    await act(async () => root.unmount());
    await act(async () => second.root.unmount());
  });

  it.each(["ready_to_transfer", "transferring", "completed", "cancelled"] as const)(
    "hides the trash button when the status is %s",
    async (status) => {
      const { node, root } = await render(operation({ status: status as RemittanceOperationStatus }), { role: "owner" });

      expect(deleteButton(node)).toBeNull();
      await act(async () => root.unmount());
    },
  );

  it("hides the trash button on a history operation", async () => {
    const { node, root } = await render(operation({ status: "incident", isHistory: true }), { role: "owner" });

    expect(deleteButton(node)).toBeNull();
    await act(async () => root.unmount());
  });

  it.each(["ready_to_transfer", "transferring"] as const)("owner sees Close manually when the status is %s", async (status) => {
    const { node, root } = await render(operation({ status }), { role: "owner" });

    expect(closeButton(node)).toBeTruthy();
    await act(async () => root.unmount());
  });

  it("hides Close manually for other statuses", async () => {
    const { node, root } = await render(operation({ status: "deposit_verification" }), { role: "owner" });

    expect(closeButton(node)).toBeFalsy();
    await act(async () => root.unmount());
  });

  it("clicking the trash opens the delete form; done refreshes the panel and closes it", async () => {
    const onChanged = vi.fn();
    const { node, root } = await render(operation({ status: "deposit_verification" }), { role: "admin", onChanged });

    await act(async () => (deleteButton(node) as HTMLButtonElement).click());
    expect(node.querySelector('[data-testid="closing-stub"]')?.getAttribute("data-kind")).toBe("delete");

    await act(async () => (node.querySelector('[data-testid="closing-done"]') as HTMLButtonElement).click());
    expect(onChanged).toHaveBeenCalled();
    expect(node.querySelector('[data-testid="closing-stub"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("clicking Close manually opens the close form", async () => {
    const { node, root } = await render(operation({ status: "ready_to_transfer" }), { role: "owner" });

    await act(async () => (closeButton(node) as HTMLButtonElement).click());

    expect(node.querySelector('[data-testid="closing-stub"]')?.getAttribute("data-kind")).toBe("close");
    await act(async () => root.unmount());
  });

  it("labels a history operation closed manually where delivered ones show their delivery info", async () => {
    const { node, root } = await render(
      operation({ status: "completed", isHistory: true, deliveryMode: "closed_manually", completedAt: "2026-10-02T10:00:00Z" }),
      { role: "owner", expanded: false },
    );

    expect(node.textContent).toContain(en.Inbox.operationsPanel.history.closedManually);
    await act(async () => root.unmount());
  });
});
