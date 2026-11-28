// @vitest-environment jsdom
// Spec: panel-fully-editable T2. Creating an operation from scratch in the open conversation: a button opens an inline form (service +
// deposit in GYD), one request to crearOperacion, the new operation id handed to the panel, the server's refusal shown as its message.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const crearOperacion = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  crearOperacion: (...args: unknown[]) => crearOperacion(...args),
}));

// The app's Select (Base UI) hangs under jsdom; a native double keeps the value/onValueChange contract.
vi.mock("@/components/ui/select", () => ({
  Select: ({ id, value, disabled, onValueChange, children }: {
    id?: string; value?: string; disabled?: boolean; onValueChange?: (value: string) => void; children?: React.ReactNode;
  }) => (
    <select id={id} value={value} disabled={disabled} onChange={(event) => onValueChange?.(event.target.value)}>
      <option value="" />
      {children}
    </select>
  ),
  SelectTrigger: () => null,
  SelectValue: () => null,
  SelectContent: ({ children }: { children?: React.ReactNode }) => <>{children}</>,
  SelectItem: ({ value, children }: { value: string; children?: React.ReactNode }) => <option value={value}>{children}</option>,
}));

afterEach(() => {
  document.body.replaceChildren();
  crearOperacion.mockReset();
});

const P = en.Inbox.operationsPanel;

async function render(onCreated = vi.fn()) {
  const { OperationCreateControl } = await import("./operation-create-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationCreateControl conversationId="conv-1" onCreated={onCreated} />));
  return { node, root, onCreated };
}

const click = (el: Element | null) => act(async () => el!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
const openButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${P.newOperation}"]`);
const confirmButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${P.confirmNewOperation}"]`) as HTMLButtonElement | null;
const cancelButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${P.cancel}"]`);

function pickService(node: HTMLElement, value: string) {
  const select = node.querySelector<HTMLSelectElement>("select")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function typeAmount(node: HTMLElement, value: string) {
  const input = node.querySelector<HTMLInputElement>("#new-operation-amount")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

const submit = (node: HTMLElement) => act(async () => node.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));

describe("OperationCreateControl", () => {
  it("starts as a button; the form opens on click", async () => {
    const { node, root } = await render();

    expect(openButton(node)).not.toBeNull();
    expect(node.querySelector("form")).toBeNull();
    await click(openButton(node));
    expect(node.querySelector("form")).not.toBeNull();
    expect(node.querySelector("select")).not.toBeNull();
    expect(node.querySelector("#new-operation-amount")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("creates the operation with the chosen service and amount and hands its id to the panel", async () => {
    crearOperacion.mockResolvedValue({ ok: true, id: "op-9", service: "zelle" });
    const { node, root, onCreated } = await render();
    await click(openButton(node));

    await act(async () => pickService(node, "zelle"));
    await act(async () => typeAmount(node, "13,000"));
    await submit(node);

    expect(crearOperacion).toHaveBeenCalledWith("conv-1", "zelle", 13000);
    expect(onCreated).toHaveBeenCalledWith("op-9");
    expect(node.querySelector("form")).toBeNull();
    await act(async () => root.unmount());
  });

  it("a combo may go without an amount", async () => {
    crearOperacion.mockResolvedValue({ ok: true, id: "op-10", service: "combo" });
    const { node, root, onCreated } = await render();
    await click(openButton(node));

    await act(async () => pickService(node, "combo"));
    await submit(node);

    expect(crearOperacion).toHaveBeenCalledWith("conv-1", "combo", null);
    expect(onCreated).toHaveBeenCalledWith("op-10");
    await act(async () => root.unmount());
  });

  it("any other service needs an amount: nothing is sent and the form says so", async () => {
    const { node, root, onCreated } = await render();
    await click(openButton(node));

    await act(async () => pickService(node, "zelle"));
    await submit(node);

    expect(node.textContent).toContain(P.invalidAmount);
    expect(crearOperacion).not.toHaveBeenCalled();
    expect(onCreated).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("without a service nothing is sent", async () => {
    const { node, root } = await render();
    await click(openButton(node));

    await act(async () => typeAmount(node, "13000"));
    await submit(node);

    expect(crearOperacion).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("a refusal shows the server's message and keeps the form open", async () => {
    crearOperacion.mockResolvedValue({ ok: false, status: 403, error: "not authorized to create an operation in this conversation" });
    const { node, root, onCreated } = await render();
    await click(openButton(node));

    await act(async () => pickService(node, "zelle"));
    await act(async () => typeAmount(node, "13000"));
    await submit(node);

    expect(node.textContent).toContain("not authorized to create an operation in this conversation");
    expect(node.querySelector("form")).not.toBeNull();
    expect(onCreated).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancel closes the form without sending anything", async () => {
    const { node, root } = await render();
    await click(openButton(node));

    await click(cancelButton(node));

    expect(node.querySelector("form")).toBeNull();
    expect(crearOperacion).not.toHaveBeenCalled();
    expect(confirmButton(node)).toBeNull();
    await act(async () => root.unmount());
  });
});
