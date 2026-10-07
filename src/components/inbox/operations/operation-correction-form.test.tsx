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
const cambiarServicio = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: (...args: unknown[]) => corregirOperacion(...args),
  cambiarServicio: (...args: unknown[]) => cambiarServicio(...args),
}));

// The form uses the app's Select (Base UI: a portal popup driven by pointer
// events, which hangs under jsdom). These tests cover the form's logic, so the
// control is replaced by a native select with the same value/onValueChange
// contract; the trigger's label rendering is not under test here.
vi.mock("@/components/ui/select", () => ({
  Select: ({ id, value, disabled, onValueChange, children }: {
    id?: string; value?: string; disabled?: boolean; onValueChange?: (value: string) => void; children?: React.ReactNode;
  }) => (
    <select id={id} value={value} disabled={disabled} onChange={(event) => onValueChange?.(event.target.value)}>
      {children}
    </select>
  ),
  SelectTrigger: () => null,
  SelectValue: () => null,
  SelectContent: ({ children }: { children?: React.ReactNode }) => <>{children}</>,
  SelectItem: ({ value, children }: { value: string; children?: React.ReactNode }) => <option value={value}>{children}</option>,
}));

const toast = { success: vi.fn(), error: vi.fn() };
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toast.success(...a), error: (...a: unknown[]) => toast.error(...a) } }));

afterEach(() => {
  corregirOperacion.mockReset();
  cambiarServicio.mockReset();
  toast.success.mockReset();
  toast.error.mockReset();
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
    quotedDestinationRate: null,
    quotedDestinationOrigin: null,
    adminLockedFields: {},
    createdAt: "2026-09-14T00:00:00Z",
    completedAt: null,
    isHistory: false,
    beneficiariesComplete: false,
    deliveryMode: null,
    deliveredAt: null,
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

  describe("service field", () => {
    const serviceSelect = (node: HTMLElement) => node.querySelector<HTMLSelectElement>("#operation-service")!;
    const warning = en.Inbox.operationsPanel.serviceChange.warning;
    const pick = (select: HTMLSelectElement, value: string) =>
      act(async () => {
        const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
        setter.call(select, value);
        select.dispatchEvent(new Event("change", { bubbles: true }));
      });
    const button = (node: HTMLElement, label: string) =>
      node.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!;

    it("shows the Servicio select with the current service, in the same field layout as the others", async () => {
      const { node, root } = await render(operation({ deliveryMethod: "clasica" }));

      expect(serviceSelect(node).value).toBe("clasica");
      expect(node.querySelector('label[for="operation-service"]')!.textContent).toBe(en.Inbox.operationsPanel.serviceChange.label);
      expect(node.textContent).not.toContain(warning);
      await act(async () => root.unmount());
    });

    it("confirms with a check and cancels with an X (icon buttons)", async () => {
      const { node, root, onCancel } = await render(operation());
      const t = en.Inbox.operationsPanel;

      expect(button(node, t.save).querySelector("svg")).not.toBeNull();
      await act(async () => button(node, t.cancel).click());
      expect(onCancel).toHaveBeenCalledTimes(1);
      expect(cambiarServicio).not.toHaveBeenCalled();
      await act(async () => root.unmount());
    });

    it("shows the warning only when a different service is chosen", async () => {
      const { node, root } = await render(operation({ deliveryMethod: "clasica" }));

      await pick(serviceSelect(node), "zelle");
      expect(node.textContent).toContain(warning);
      await pick(serviceSelect(node), "clasica");
      expect(node.textContent).not.toContain(warning);
      await act(async () => root.unmount());
    });

    it("the check changes the service first, then sends the other corrections, then finishes", async () => {
      const order: string[] = [];
      cambiarServicio.mockImplementation(async () => (order.push("service"), { ok: true }));
      corregirOperacion.mockImplementation(async () => (order.push("corrections"), { ok: true, id: "op-1" }));
      const { node, root, onDone } = await render(operation({ deliveryMethod: "clasica" }));

      await pick(serviceSelect(node), "zelle");
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!, "12000"));
      await submit(node);

      expect(cambiarServicio).toHaveBeenCalledWith("op-1", "zelle");
      expect(corregirOperacion).toHaveBeenCalledWith("op-1", { quoted_source_amount: 12000 });
      expect(order).toEqual(["service", "corrections"]);
      expect(toast.success).toHaveBeenCalledTimes(1);
      expect(onDone).toHaveBeenCalledTimes(1);
      await act(async () => root.unmount());
    });

    it("a service-only change does not call corregirOperacion", async () => {
      cambiarServicio.mockResolvedValue({ ok: true });
      const { node, root, onDone } = await render(operation({ deliveryMethod: "clasica" }));

      await pick(serviceSelect(node), "recarga");
      await submit(node);

      expect(cambiarServicio).toHaveBeenCalledWith("op-1", "recarga");
      expect(corregirOperacion).not.toHaveBeenCalled();
      expect(onDone).toHaveBeenCalledTimes(1);
      await act(async () => root.unmount());
    });

    it("an unchanged service is never sent", async () => {
      corregirOperacion.mockResolvedValue({ ok: true, id: "op-1" });
      const { node, root } = await render(operation({ deliveryMethod: "clasica" }));

      await act(async () => setValue(node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!, "12000"));
      await submit(node);

      expect(cambiarServicio).not.toHaveBeenCalled();
      await act(async () => root.unmount());
    });

    it("a service error shows a toast, restores the select and sends nothing else", async () => {
      cambiarServicio.mockResolvedValue({ ok: false, status: 422, error: "Not allowed" });
      const { node, root, onDone } = await render(operation({ deliveryMethod: "clasica" }));

      await pick(serviceSelect(node), "zelle");
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!, "12000"));
      await submit(node);

      expect(toast.error).toHaveBeenCalledTimes(1);
      expect(serviceSelect(node).value).toBe("clasica");
      expect(corregirOperacion).not.toHaveBeenCalled();
      expect(onDone).not.toHaveBeenCalled();
      await act(async () => root.unmount());
    });

    it("an invalid other field blocks everything before the service is changed", async () => {
      const { node, root } = await render(operation({ deliveryMethod: "clasica" }));

      await pick(serviceSelect(node), "zelle");
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!, "-1"));
      await submit(node);

      expect(cambiarServicio).not.toHaveBeenCalled();
      expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidAmount);
      await act(async () => root.unmount());
    });

    it("when the service changed but the other corrections fail, it reports it and refreshes", async () => {
      cambiarServicio.mockResolvedValue({ ok: true });
      corregirOperacion.mockResolvedValue({ ok: false, status: 422, error: "Amount exceeds limit" });
      const { node, root, onDone } = await render(operation({ deliveryMethod: "clasica" }));

      await pick(serviceSelect(node), "zelle");
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#operation-quoted-source-amount")!, "12000"));
      await submit(node);

      expect(toast.error).toHaveBeenCalledTimes(1);
      expect(onDone).toHaveBeenCalledTimes(1);
      await act(async () => root.unmount());
    });
  });
});
