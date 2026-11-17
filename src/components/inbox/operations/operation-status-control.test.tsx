// @vitest-environment jsdom
// Spec: panel-fully-editable T4. Moving an open operation between open states from its card: a select of the four allowed states, the
// notify bell only for ready_to_transfer (default off), one request to cambiarEstado, the server's refusal shown as its message.

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

const cambiarEstado = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  cambiarEstado: (...args: unknown[]) => cambiarEstado(...args),
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
  cambiarEstado.mockReset();
});

const P = en.Inbox.operationsPanel;

async function render(currentStatus = "collecting_information", onDone = vi.fn(), onCancel = vi.fn()) {
  const { OperationStatusControl } = await import("./operation-status-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationStatusControl operationId="op-1" currentStatus={currentStatus} onDone={onDone} onCancel={onCancel} />));
  return { node, root, onDone, onCancel };
}

function pick(node: HTMLElement, value: string) {
  const select = node.querySelector<HTMLSelectElement>("select")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}
const submit = (node: HTMLElement) => act(async () => node.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
const bell = (node: HTMLElement) => node.querySelector(`button[aria-pressed]`) as HTMLButtonElement | null;
const options = (node: HTMLElement) => Array.from(node.querySelectorAll("option")).map((o) => o.value).filter(Boolean);

describe("OperationStatusControl", () => {
  it("offers the four open states, not the current one, and neither completed nor cancelled", async () => {
    const { node, root } = await render("collecting_information");

    expect(options(node)).toEqual(["awaiting_deposit", "deposit_verification", "ready_to_transfer"]);
    await act(async () => root.unmount());

    const b = await render("deposit_verification");
    expect(options(b.node)).toEqual(["collecting_information", "awaiting_deposit", "ready_to_transfer"]);
    await act(async () => b.root.unmount());
  });

  it("an operation in a state outside the four (an incident) can go to any of the four", async () => {
    const { node, root } = await render("incident");

    expect(options(node)).toEqual(["collecting_information", "awaiting_deposit", "deposit_verification", "ready_to_transfer"]);
    await act(async () => root.unmount());
  });

  it("moves the operation with the bell off by default and hands control back", async () => {
    cambiarEstado.mockResolvedValue({ ok: true, changed: true, newStatus: "deposit_verification" });
    const { node, root, onDone } = await render("collecting_information");

    await act(async () => pick(node, "deposit_verification"));
    expect(bell(node)).toBeNull();
    await submit(node);

    expect(cambiarEstado).toHaveBeenCalledWith("op-1", "deposit_verification", false);
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("the bell shows only for ready_to_transfer, starts off and can be turned on", async () => {
    cambiarEstado.mockResolvedValue({ ok: true, changed: true, newStatus: "ready_to_transfer" });
    const { node, root } = await render("deposit_verification");

    await act(async () => pick(node, "ready_to_transfer"));
    expect(bell(node)).not.toBeNull();
    expect(bell(node)!.getAttribute("aria-pressed")).toBe("false");
    await act(async () => bell(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await submit(node);

    expect(cambiarEstado).toHaveBeenCalledWith("op-1", "ready_to_transfer", true);
    await act(async () => root.unmount());
  });

  it("nothing is sent until a state is chosen", async () => {
    const { node, root } = await render();

    await submit(node);

    expect(cambiarEstado).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("a refusal shows the server's message and does not finish", async () => {
    cambiarEstado.mockResolvedValue({ ok: false, status: 400, error: "operation is closed" });
    const { node, root, onDone } = await render();

    await act(async () => pick(node, "awaiting_deposit"));
    await submit(node);

    expect(node.textContent).toContain("operation is closed");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancel closes the form without sending anything", async () => {
    const { node, root, onCancel } = await render();

    await act(async () => (node.querySelector(`button[aria-label="${P.cancel}"]`) as HTMLButtonElement).dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(cambiarEstado).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
