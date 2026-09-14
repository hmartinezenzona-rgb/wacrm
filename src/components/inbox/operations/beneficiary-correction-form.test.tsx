// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel correction UI. `cardNumber`/`phone`
// start empty (never re-display the raw value) and are only sent when the
// agent actually types a new one; other fields are prefilled and only sent
// when changed.

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
    name: "Yaima Perez",
    cardNumberMasked: "9205****9412",
    phoneMasked: "*******1111",
    zelleAccount: null,
    deliveryMethod: "home",
    amount: 100,
    currency: "USD",
    position: 1,
    ...overrides,
  };
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
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
  it("prefills card/phone as empty with the masked value as placeholder", async () => {
    const { node, root } = await render(beneficiary());

    const cardInput = node.querySelector<HTMLInputElement>("#beneficiary-card-number")!;
    const phoneInput = node.querySelector<HTMLInputElement>("#beneficiary-phone")!;
    expect(cardInput.value).toBe("");
    expect(cardInput.placeholder).toBe("9205****9412");
    expect(phoneInput.value).toBe("");
    expect(phoneInput.placeholder).toBe("*******1111");
    await act(async () => root.unmount());
  });

  it("does not send card_number/phone when left empty, even if another field changed", async () => {
    corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
    const { node, root, onDone } = await render(beneficiary());

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
    const { node, root, onDone } = await render(beneficiary());

    const nameInput = node.querySelector<HTMLInputElement>("#beneficiary-name")!;
    await act(async () => setValue(nameInput, "New Name"));
    await submit(node);

    expect(node.textContent).toContain("Beneficiary locked");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
