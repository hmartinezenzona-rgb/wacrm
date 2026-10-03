// @vitest-environment jsdom
// Spec: odd/tasks/remesa-closing-and-cash.md (B+D). The inline confirmation
// for the two owner/admin panel actions — close a verified remesa manually
// (customer NOT notified) and delete a remesa — each requiring a reason.

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

const cerrarOperacionManual = vi.fn();
const eliminarOperacion = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  cerrarOperacionManual: (...args: unknown[]) => cerrarOperacionManual(...args),
  eliminarOperacion: (...args: unknown[]) => eliminarOperacion(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  cerrarOperacionManual.mockReset();
  eliminarOperacion.mockReset();
});

const t = en.Inbox.operationsPanel.closing;

function setValue(input: HTMLTextAreaElement | HTMLInputElement, value: string) {
  const proto = input instanceof HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function buttonByText(node: Element, text: string): HTMLButtonElement {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as HTMLButtonElement;
}

async function render(kind: "close" | "delete", onDone = vi.fn(), onCancel = vi.fn()) {
  const { OperationClosingControl } = await import("./operation-closing-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(<OperationClosingControl operationId="op-1" kind={kind} onDone={onDone} onCancel={onCancel} />),
  );
  return { node, root, onDone, onCancel };
}

describe("OperationClosingControl", () => {
  it("close: warns the customer will not be notified and keeps confirm disabled without a reason", async () => {
    const { node, root } = await render("close");

    expect(node.textContent).toContain(t.closeWarning);
    expect(buttonByText(node, t.closeConfirm).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("close: confirms with the trimmed reason via cerrarOperacionManual, then onDone", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root, onDone } = await render("close");

    await act(async () => setValue(node.querySelector("textarea")!, "  Transferred by hand  "));
    await act(async () => buttonByText(node, t.closeConfirm).click());

    expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", "Transferred by hand");
    expect(eliminarOperacion).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("delete: confirms with the reason via eliminarOperacion, then onDone", async () => {
    eliminarOperacion.mockResolvedValue({ ok: true, newStatus: "cancelled" });
    const { node, root, onDone } = await render("delete");

    expect(node.textContent).toContain(t.deleteWarning);
    await act(async () => setValue(node.querySelector("textarea")!, "Duplicate receipt"));
    await act(async () => buttonByText(node, t.deleteConfirm).click());

    expect(eliminarOperacion).toHaveBeenCalledWith("op-1", "Duplicate receipt");
    expect(cerrarOperacionManual).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server error and does not call onDone when the command fails", async () => {
    eliminarOperacion.mockResolvedValue({ ok: false, status: 400, error: "remesa holds a consumed deposit" });
    const { node, root, onDone } = await render("delete");

    await act(async () => setValue(node.querySelector("textarea")!, "Duplicate receipt"));
    await act(async () => buttonByText(node, t.deleteConfirm).click());

    expect(node.textContent).toContain("remesa holds a consumed deposit");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancel calls onCancel without any command", async () => {
    const { node, root, onCancel } = await render("close");

    await act(async () => buttonByText(node, en.Inbox.operationsPanel.cancel).click());

    expect(onCancel).toHaveBeenCalled();
    expect(cerrarOperacionManual).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
