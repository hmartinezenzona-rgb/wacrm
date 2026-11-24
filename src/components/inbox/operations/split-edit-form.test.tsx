// @vitest-environment jsdom
// "Editar reparto": one table of the card shares, a live sum against the operation total, and a single save through
// editarReparto (crm_editar_reparto). Existing rows keep their id, new rows send null.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceBeneficiaryRead } from "@/lib/remittance-operations/types";

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

const editarReparto = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  editarReparto: (...args: unknown[]) => editarReparto(...args),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn() } }));

afterEach(() => {
  document.body.replaceChildren();
  editarReparto.mockReset();
});

const E = en.Inbox.operationsPanel.editSplit;
const P = en.Inbox.operationsPanel;

function share(id: string, amount: number | null, card: string, overrides: Partial<RemittanceBeneficiaryRead> = {}): RemittanceBeneficiaryRead {
  return {
    id,
    beneficiaryType: "cuban_card",
    name: null,
    cardNumber: card,
    phone: null,
    zelleAccount: null,
    deliveryMethod: null,
    amount,
    amountOrigin: "manual",
    currency: "CUP",
    position: 0,
    address: null,
    ...overrides,
  } as RemittanceBeneficiaryRead;
}

const SHARES = [
  share("ben-1", 100, "9205000000000001", { name: "Persona Uno", phone: "55500001" }),
  share("ben-2", 50, "9205000000000002"),
];

async function render(options: { shares?: RemittanceBeneficiaryRead[]; total?: number | null } = {}) {
  const { SplitEditForm } = await import("./split-edit-form");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onDone = vi.fn();
  const onCancel = vi.fn();
  await act(async () =>
    root.render(
      <SplitEditForm
        operationId="op-1"
        beneficiaries={options.shares ?? SHARES}
        total={options.total === undefined ? 150 : options.total}
        currency="CUP"
        onDone={onDone}
        onCancel={onCancel}
      />,
    ),
  );
  return { node, root, onDone, onCancel };
}

const inputs = (node: Element, label: string) => Array.from(node.querySelectorAll<HTMLInputElement>(`input[aria-label="${label}"]`));
const saveButton = (node: Element) => node.querySelector<HTMLButtonElement>(`button[aria-label="${E.confirm}"]`)!;
const button = (node: Element, label: string) => Array.from(node.querySelectorAll<HTMLButtonElement>(`button[aria-label="${label}"]`));

async function type(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

describe("canEditSplit", () => {
  it("is true for a remesa whose recipients (none, one or several) are all card rails", async () => {
    const { canEditSplit } = await import("./split-edit-form");
    const op = (serviceType: string, shares: RemittanceBeneficiaryRead[]) => ({ serviceType, beneficiaries: shares }) as never;

    expect(canEditSplit(op("remesa", SHARES))).toBe(true);
    expect(canEditSplit(op("remesa", [SHARES[0]!]))).toBe(true);
    expect(canEditSplit(op("remesa", []))).toBe(true);
    expect(canEditSplit(op("recarga", SHARES))).toBe(false);
    expect(canEditSplit(op("remesa", [...SHARES, share("z", 1, "", { beneficiaryType: "zelle" })]))).toBe(false);
    expect(canEditSplit(op("remesa", [share("a", 1, "1", { beneficiaryType: "clasica" }), share("b", 1, "1", { beneficiaryType: "multiple_distribution" })]))).toBe(true);
  });
});

describe("SplitEditForm", () => {
  it("pads the rows with empty ones up to two when the operation has fewer shares", async () => {
    const one = await render({ shares: [SHARES[0]!], total: 150 });
    expect(inputs(one.node, E.card).map((i) => i.value)).toEqual(["9205000000000001", ""]);
    expect(saveButton(one.node).disabled).toBe(true);
    await act(async () => one.root.unmount());

    const none = await render({ shares: [], total: 150 });
    expect(inputs(none.node, E.card)).toHaveLength(2);
    await type(inputs(none.node, E.card)[0]!, "9205000000000001");
    await type(inputs(none.node, E.amount)[0]!, "100");
    await type(inputs(none.node, E.card)[1]!, "9205000000000002");
    await type(inputs(none.node, E.amount)[1]!, "50");
    expect(saveButton(none.node).disabled).toBe(false);
    await act(async () => saveButton(none.node).click());
    expect(editarReparto).toHaveBeenCalledWith("op-1", [
      expect.objectContaining({ id: null, card_number: "9205000000000001", amount: 100 }),
      expect.objectContaining({ id: null, card_number: "9205000000000002", amount: 50 }),
    ]);
    await act(async () => none.root.unmount());
  });

  it("lists one row per share prefilled and shows the matching sum", async () => {
    const { node, root } = await render();

    expect(inputs(node, E.card).map((i) => i.value)).toEqual(["9205000000000001", "9205000000000002"]);
    expect(inputs(node, E.name).map((i) => i.value)).toEqual(["Persona Uno", ""]);
    expect(inputs(node, E.phone).map((i) => i.value)).toEqual(["55500001", ""]);
    expect(inputs(node, E.amount).map((i) => i.value)).toEqual(["100", "50"]);
    expect(node.textContent).toContain("Sum 150 CUP / Total 150 CUP — difference 0");
    expect(saveButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("updates the sum live and locks save while it differs from the total", async () => {
    const { node, root } = await render();

    await type(inputs(node, E.amount)[1]!, "40");

    expect(node.textContent).toContain("Sum 140 CUP / Total 150 CUP — difference -10");
    expect(saveButton(node).disabled).toBe(true);

    await type(inputs(node, E.amount)[1]!, "60");
    expect(node.textContent).toContain("difference 10");
    expect(saveButton(node).disabled).toBe(true);

    await type(inputs(node, E.amount)[1]!, "50");
    expect(saveButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it.each([
    ["a card that is not 16 digits", E.card, "920500"],
    ["a phone that is not 8 to 15 digits", E.phone, "123"],
  ])("locks save for %s", async (_label, field, value) => {
    const { node, root } = await render();

    await type(inputs(node, field)[0]!, value);

    expect(saveButton(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("accepts spaces and dashes in the card and an empty phone", async () => {
    const { node, root } = await render();

    await type(inputs(node, E.card)[0]!, "9205 0000-0000 0001");
    await type(inputs(node, E.phone)[0]!, "");

    expect(saveButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("locks save when the operation has no total", async () => {
    const { node, root } = await render({ total: null });

    expect(node.textContent).toContain(E.noTotal);
    expect(saveButton(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("adds a row (empty, locking save) and removes one, never below two", async () => {
    const { node, root } = await render();

    await act(async () => button(node, E.addRow)[0]!.click());
    expect(inputs(node, E.card)).toHaveLength(3);
    expect(saveButton(node).disabled).toBe(true);

    await act(async () => button(node, E.removeRow)[2]!.click());
    expect(inputs(node, E.card)).toHaveLength(2);
    // With two rows left the remove buttons are gone: a split needs at least two shares.
    expect(button(node, E.removeRow)).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("saves once with the ids of kept shares and null for a new one", async () => {
    editarReparto.mockResolvedValue({ ok: true, retired: [], created: ["new"], kept: ["ben-1"], complete: true });
    const { node, root, onDone } = await render();

    await type(inputs(node, E.amount)[1]!, "30");
    await act(async () => button(node, E.addRow)[0]!.click());
    await type(inputs(node, E.name)[2]!, " Persona Tres ");
    await type(inputs(node, E.card)[2]!, "9205 0000 0000 0003");
    await type(inputs(node, E.amount)[2]!, "20");
    await act(async () => saveButton(node).click());

    expect(editarReparto).toHaveBeenCalledTimes(1);
    expect(editarReparto).toHaveBeenCalledWith("op-1", [
      { id: "ben-1", beneficiary_type: "cuban_card", name: "Persona Uno", card_number: "9205000000000001", phone: "55500001", amount: 100, currency: "CUP" },
      { id: "ben-2", beneficiary_type: "cuban_card", name: null, card_number: "9205000000000002", phone: null, amount: 30, currency: "CUP" },
      { id: null, beneficiary_type: "cuban_card", name: "Persona Tres", card_number: "9205000000000003", phone: null, amount: 20, currency: "CUP" },
    ]);
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("shows the server's refusal and stays open", async () => {
    editarReparto.mockResolvedValue({ ok: false, status: 400, error: "Parte 1: la tarjeta debe tener exactamente 16 dígitos" });
    const { node, root, onDone } = await render();

    await act(async () => saveButton(node).click());

    expect(node.textContent).toContain("Parte 1: la tarjeta debe tener exactamente 16 dígitos");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancel closes without a request", async () => {
    const { node, root, onCancel } = await render();

    await act(async () => button(node, P.cancel)[0]!.click());

    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(editarReparto).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
