// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel correction UI. Sends only the
// admin-owned fields the agent actually changed, snake_case keys, amounts
// as numbers — mirrors `corregirOperacion`'s `cambios` contract exactly.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const corregirOperacion = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: (...args: unknown[]) => corregirOperacion(...args),
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
    destinationCurrency: "USD",
    deliveryMethod: "cash",
    depositMethod: "bank",
    quotedSourceAmount: 10000,
    quotedDestinationAmount: 50,
    adminLockedFields: {},
    createdAt: "2026-09-14T00:00:00Z",
    completedAt: null,
    beneficiaries: [],
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

async function render(op: RemittanceOperationRead, onDone = vi.fn(), onCancel = vi.fn()) {
  const { OperationCorrectionForm } = await import("./operation-correction-form");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationCorrectionForm operation={op} onDone={onDone} onCancel={onCancel} />));
  return { node, root, onDone, onCancel };
}

describe("OperationCorrectionForm", () => {
  it("sends only the changed fields with snake_case keys and amounts as numbers", async () => {
    corregirOperacion.mockResolvedValue({ ok: true, id: "op-1" });
    const { node, root, onDone } = await render(operation());

    const amountInput = node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!;
    await act(async () => setValue(amountInput, "12000"));
    await submit(node);

    expect(corregirOperacion).toHaveBeenCalledWith("op-1", { quoted_source_amount: 12000 });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("blocks submit and shows a message when the amount is not > 0", async () => {
    const { node, root } = await render(operation());

    const amountInput = node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!;
    await act(async () => setValue(amountInput, "0"));
    await submit(node);

    expect(corregirOperacion).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidAmount);
    await act(async () => root.unmount());
  });

  it("blocks submit and shows a message when the currency doesn't match ^[A-Z]{3}$", async () => {
    const { node, root } = await render(operation());

    const currencyInput = node.querySelector<HTMLInputElement>("#operation-destination-currency")!;
    await act(async () => setValue(currencyInput, "usd"));
    await submit(node);

    expect(corregirOperacion).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidCurrency);
    await act(async () => root.unmount());
  });

  it("shows noChanges and calls nothing when nothing changed", async () => {
    const { node, root } = await render(operation());

    await submit(node);

    expect(corregirOperacion).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.noChanges);
    await act(async () => root.unmount());
  });

  it("shows the server error text on failure and does not call onDone", async () => {
    corregirOperacion.mockResolvedValue({ ok: false, status: 422, error: "Amount exceeds limit" });
    const { node, root, onDone } = await render(operation());

    const amountInput = node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!;
    await act(async () => setValue(amountInput, "12000"));
    await submit(node);

    expect(node.textContent).toContain("Amount exceeds limit");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
