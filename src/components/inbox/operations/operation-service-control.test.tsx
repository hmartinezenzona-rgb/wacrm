// @vitest-environment jsdom
// Spec: odd/tasks/change-operation-service.md (T2). The "Servicio" selector of an open operation: eight services, the
// current one preselected, a confirmation step that says what changes (quote recalculated, recipients that do not fit
// removed, customer not messaged) before anything is sent, a toast after the change and an error toast on failure.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { OperationService } from "@/lib/remittance-operations/services";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, string>) => {
      const value = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      return params ? value.replace(/\{(\w+)\}/g, (_m, name: string) => params[name] ?? "") : value;
    };
  },
}));

const cambiarServicio = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  cambiarServicio: (...args: unknown[]) => cambiarServicio(...args),
}));

const toastSuccess = vi.fn();
const toastError = vi.fn();
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  cambiarServicio.mockReset();
  toastSuccess.mockReset();
  toastError.mockReset();
});

const t = en.Inbox.operationsPanel;

async function render(current: OperationService | null, onDone = vi.fn()) {
  const { OperationServiceControl } = await import("./operation-service-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationServiceControl operationId="op-1" current={current} onDone={onDone} />));
  return { node, root, onDone };
}

function select(node: Element): HTMLSelectElement {
  return node.querySelector("select") as HTMLSelectElement;
}

async function choose(node: Element, value: string) {
  const el = select(node);
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!;
    setter.call(el, value);
    el.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

function buttonByText(node: Element, text: string): HTMLButtonElement {
  return [...node.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as HTMLButtonElement;
}

describe("currentServiceOf", () => {
  it("reads the service from the operation: service type first, then delivery method, then the recipient's type", async () => {
    const { currentServiceOf } = await import("./operation-service-control");
    const base = { serviceType: "remesa", deliveryMethod: null, beneficiaries: [] as { beneficiaryType: string }[] };

    expect(currentServiceOf({ ...base, serviceType: "recarga", deliveryMethod: "clasica" } as never)).toBe("recarga");
    expect(currentServiceOf({ ...base, serviceType: "combo" } as never)).toBe("combo");
    expect(currentServiceOf({ ...base, serviceType: "visa" } as never)).toBe("visa");
    expect(currentServiceOf({ ...base, deliveryMethod: "tropical" } as never)).toBe("tropical");
    expect(currentServiceOf({ ...base, beneficiaries: [{ beneficiaryType: "zelle" }] } as never)).toBe("zelle");
    expect(currentServiceOf(base as never)).toBeNull();
    expect(currentServiceOf({ ...base, deliveryMethod: "mmg" } as never)).toBeNull();
  });
});

describe("OperationServiceControl", () => {
  it("lists the eight services with the catalog labels and preselects the current one", async () => {
    const { node, root } = await render("clasica");

    const labels = [...select(node).querySelectorAll("option")].map((o) => o.textContent);
    expect(labels).toEqual([
      t.closing.method.cuban_card,
      t.closing.method.zelle,
      t.closing.method.clasica,
      t.closing.method.tropical,
      t.closing.method.efectivo_usd,
      t.closing.method.recarga,
      t.closing.method.combo,
      t.closing.method.visa,
    ]);
    expect(select(node).value).toBe("clasica");
    expect(node.textContent).toContain(t.serviceChange.label);
    act(() => root.unmount());
  });

  it("with no known service yet, offers a placeholder and no confirmation", async () => {
    const { node, root } = await render(null);

    expect(select(node).value).toBe("");
    expect(node.textContent).not.toContain(t.serviceChange.warning);
    act(() => root.unmount());
  });

  it("choosing another service asks for confirmation first and sends nothing yet", async () => {
    const { node, root } = await render("cuban_card");

    await choose(node, "recarga");

    expect(node.textContent).toContain(t.serviceChange.warning);
    expect(cambiarServicio).not.toHaveBeenCalled();
    act(() => root.unmount());
  });

  it("the warning says the quote is recalculated, recipients that do not fit go, and the customer is not messaged", () => {
    expect(t.serviceChange.warning).toMatch(/recalculated/i);
    expect(t.serviceChange.warning).toMatch(/removed/i);
    expect(t.serviceChange.warning).toMatch(/not messaged/i);
  });

  it("cancelling puts the selector back and sends nothing", async () => {
    const { node, root } = await render("cuban_card");
    await choose(node, "zelle");

    await act(async () => buttonByText(node, t.cancel).click());

    expect(select(node).value).toBe("cuban_card");
    expect(node.textContent).not.toContain(t.serviceChange.warning);
    expect(cambiarServicio).not.toHaveBeenCalled();
    act(() => root.unmount());
  });

  it("confirming sends the change, toasts and refreshes the panel", async () => {
    cambiarServicio.mockResolvedValueOnce({ ok: true, service: "recarga", changed: true });
    const { node, root, onDone } = await render("cuban_card");
    await choose(node, "recarga");

    await act(async () => buttonByText(node, t.serviceChange.confirm).click());

    expect(cambiarServicio).toHaveBeenCalledWith("op-1", "recarga");
    expect(toastSuccess).toHaveBeenCalledWith(t.serviceChange.saved);
    expect(onDone).toHaveBeenCalledTimes(1);
    expect(toastError).not.toHaveBeenCalled();
    act(() => root.unmount());
  });

  it("a failure shows an error toast, keeps the selector on the old service and does not refresh", async () => {
    cambiarServicio.mockResolvedValueOnce({ ok: false, status: 400, error: "operation is closed" });
    const { node, root, onDone } = await render("cuban_card");
    await choose(node, "recarga");

    await act(async () => buttonByText(node, t.serviceChange.confirm).click());

    expect(toastError).toHaveBeenCalledWith(t.serviceChange.failed.replace("{message}", "operation is closed"));
    expect(onDone).not.toHaveBeenCalled();
    expect(toastSuccess).not.toHaveBeenCalled();
    expect(select(node).value).toBe("cuban_card");
    act(() => root.unmount());
  });
});
