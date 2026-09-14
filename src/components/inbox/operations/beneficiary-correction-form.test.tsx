// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel correction UI. `cardNumber`/`phone`
// start empty in the inputs (the raw value only shows as a placeholder)
// and are only sent when the agent actually types a new one; other fields
// are prefilled and only sent when changed. Cuba beneficiary types (every
// type except "zelle") have no name — the Name and Zelle account fields
// only render for "zelle"; Card number and Phone only render for
// non-zelle types — and this follows the live `beneficiaryType` select,
// not just the beneficiary's original type.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceBeneficiaryRead } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const corregirBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirBeneficiario: (...args: unknown[]) => corregirBeneficiario(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

function beneficiary(overrides: Partial<RemittanceBeneficiaryRead> = {}): RemittanceBeneficiaryRead {
  return {
    id: "ben-1",
    beneficiaryType: "cuban_card",
    name: null,
    cardNumber: "9205123412349412",
    phone: "5355551111",
    zelleAccount: null,
    deliveryMethod: "home",
    amount: 100,
    currency: "USD",
    position: 1,
    ...overrides,
  };
}

function zelleBeneficiary(overrides: Partial<RemittanceBeneficiaryRead> = {}): RemittanceBeneficiaryRead {
  return beneficiary({
    beneficiaryType: "zelle",
    name: "Yaima Perez",
    cardNumber: null,
    phone: null,
    zelleAccount: "yaima@example.invalid",
    ...overrides,
  });
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function setSelect(select: HTMLSelectElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function submit(node: HTMLElement) {
  const form = node.querySelector("form")!;
  return act(async () => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
}

async function render(ben: RemittanceBeneficiaryRead, onDone = vi.fn(), onCancel = vi.fn()) {
  const { BeneficiaryCorrectionForm } = await import("./beneficiary-correction-form");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<BeneficiaryCorrectionForm beneficiary={ben} onDone={onDone} onCancel={onCancel} />));
  return { node, root, onDone, onCancel };
}

describe("BeneficiaryCorrectionForm", () => {
  it("prefills card/phone as empty with the raw value as placeholder", async () => {
    const { node, root } = await render(beneficiary());

    const cardInput = node.querySelector<HTMLInputElement>("#beneficiary-card-number")!;
    const phoneInput = node.querySelector<HTMLInputElement>("#beneficiary-phone")!;
    expect(cardInput.value).toBe("");
    expect(cardInput.placeholder).toBe("9205123412349412");
    expect(phoneInput.value).toBe("");
    expect(phoneInput.placeholder).toBe("5355551111");
    await act(async () => root.unmount());
  });

  it("does not send card_number/phone when left empty, even if another field changed", async () => {
    corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
    const { node, root, onDone } = await render(zelleBeneficiary());

    const nameInput = node.querySelector<HTMLInputElement>("#beneficiary-name")!;
    await act(async () => setValue(nameInput, "Yaima Perez Updated"));
    await submit(node);

    expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: "Yaima Perez Updated" });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("blocks submit when the card number is not exactly 16 digits", async () => {
    const { node, root } = await render(beneficiary());

    const cardInput = node.querySelector<HTMLInputElement>("#beneficiary-card-number")!;
    await act(async () => setValue(cardInput, "123456789012345")); // 15 digits
    await submit(node);

    expect(corregirBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidCard);
    await act(async () => root.unmount());
  });

  it("sends the expected snake_case keys for a valid multi-field change", async () => {
    corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
    const { node, root, onDone } = await render(beneficiary());

    const cardInput = node.querySelector<HTMLInputElement>("#beneficiary-card-number")!;
    const amountInput = node.querySelector<HTMLInputElement>("#beneficiary-amount")!;
    await act(async () => setValue(cardInput, "1234567890123456"));
    await act(async () => setValue(amountInput, "250"));
    await submit(node);

    expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", {
      card_number: "1234567890123456",
      amount: 250,
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server error text on failure", async () => {
    corregirBeneficiario.mockResolvedValue({ ok: false, status: 409, error: "Beneficiary locked" });
    const { node, root, onDone } = await render(zelleBeneficiary());

    const nameInput = node.querySelector<HTMLInputElement>("#beneficiary-name")!;
    await act(async () => setValue(nameInput, "New Name"));
    await submit(node);

    expect(node.textContent).toContain("Beneficiary locked");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows card number and phone but not name/zelle account for a cuban_card beneficiary", async () => {
    const { node, root } = await render(beneficiary());

    expect(node.querySelector("#beneficiary-card-number")).not.toBeNull();
    expect(node.querySelector("#beneficiary-phone")).not.toBeNull();
    expect(node.querySelector("#beneficiary-name")).toBeNull();
    expect(node.querySelector("#beneficiary-zelle-account")).toBeNull();
    await act(async () => root.unmount());
  });

  it("shows name and zelle account but not card number/phone for a zelle beneficiary", async () => {
    const { node, root } = await render(zelleBeneficiary());

    expect(node.querySelector("#beneficiary-name")).not.toBeNull();
    expect(node.querySelector("#beneficiary-zelle-account")).not.toBeNull();
    expect(node.querySelector("#beneficiary-card-number")).toBeNull();
    expect(node.querySelector("#beneficiary-phone")).toBeNull();
    await act(async () => root.unmount());
  });

  it("swaps the visible fields when the beneficiary type select changes from cuban_card to zelle", async () => {
    const { node, root } = await render(beneficiary());

    expect(node.querySelector("#beneficiary-card-number")).not.toBeNull();
    expect(node.querySelector("#beneficiary-name")).toBeNull();

    const select = node.querySelector<HTMLSelectElement>("#beneficiary-type")!;
    await act(async () => setSelect(select, "zelle"));

    expect(node.querySelector("#beneficiary-card-number")).toBeNull();
    expect(node.querySelector("#beneficiary-phone")).toBeNull();
    expect(node.querySelector("#beneficiary-name")).not.toBeNull();
    expect(node.querySelector("#beneficiary-zelle-account")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("never sends card_number for a zelle beneficiary even though it's hidden (submit with only a name change)", async () => {
    corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
    const { node, root, onDone } = await render(zelleBeneficiary());

    const nameInput = node.querySelector<HTMLInputElement>("#beneficiary-name")!;
    await act(async () => setValue(nameInput, "Yaima Perez Updated"));
    await submit(node);

    expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: "Yaima Perez Updated" });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
