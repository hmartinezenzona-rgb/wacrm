// @vitest-environment jsdom
// Spec: odd/tasks/remesa-closing-and-cash.md (E1/E2/E3). The inline
// confirmation for the two owner/admin panel actions — close a verified
// remesa manually and delete a remesa — has no reason field and only icon
// buttons (green check to confirm, X to cancel). Closing carries the
// notify-customer bell (default off); delete does not.

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

function buttonByLabel(node: Element, label: string): HTMLButtonElement {
  return node.querySelector(`button[aria-label="${label}"]`) as HTMLButtonElement;
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
  it("has no reason field and no text buttons, only icon buttons with accessible names", async () => {
    const { node, root } = await render("close");

    expect(node.querySelector("textarea")).toBeNull();
    expect(node.querySelector("label")).toBeNull();
    const confirm = buttonByLabel(node, t.closeConfirm);
    const cancel = buttonByLabel(node, en.Inbox.operationsPanel.cancel);
    expect(confirm).not.toBeNull();
    expect(cancel).not.toBeNull();
    expect(confirm.textContent?.trim()).toBe("");
    expect(cancel.textContent?.trim()).toBe("");
    expect(confirm.title).toBe(t.closeConfirm);
    expect(confirm.querySelector("svg")).not.toBeNull();
    expect(confirm.className).toContain("green");
    await act(async () => root.unmount());
  });

  it("close: confirm sends notify=false by default (bell off) and no reason, then onDone", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root, onDone } = await render("close");

    expect(node.textContent).toContain(t.closeWarning);
    const bell = node.querySelector<HTMLButtonElement>("button[aria-pressed]")!;
    expect(bell.getAttribute("aria-pressed")).toBe("false");
    expect(bell.getAttribute("aria-label")).toBe(en.Inbox.operationsPanel.notify.off);

    await act(async () => buttonByLabel(node, t.closeConfirm).click());

    expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false);
    expect(eliminarOperacion).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("close: turning the bell on sends notify=true", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root } = await render("close");

    await act(async () => node.querySelector<HTMLButtonElement>("button[aria-pressed]")!.click());
    expect(node.querySelector("button[aria-pressed]")!.getAttribute("aria-pressed")).toBe("true");
    await act(async () => buttonByLabel(node, t.closeConfirm).click());

    expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", true);
    await act(async () => root.unmount());
  });

  it("delete: no bell, confirm calls eliminarOperacion with only the operation id, then onDone", async () => {
    eliminarOperacion.mockResolvedValue({ ok: true, newStatus: "cancelled" });
    const { node, root, onDone } = await render("delete");

    expect(node.textContent).toContain(t.deleteWarning);
    expect(node.querySelector("button[aria-pressed]")).toBeNull();
    await act(async () => buttonByLabel(node, t.deleteConfirm).click());

    expect(eliminarOperacion).toHaveBeenCalledWith("op-1");
    expect(cerrarOperacionManual).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server error and does not call onDone when the command fails", async () => {
    eliminarOperacion.mockResolvedValue({ ok: false, status: 400, error: "remesa holds a consumed deposit" });
    const { node, root, onDone } = await render("delete");

    await act(async () => buttonByLabel(node, t.deleteConfirm).click());

    expect(node.textContent).toContain("remesa holds a consumed deposit");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancel calls onCancel without any command", async () => {
    const { node, root, onCancel } = await render("close");

    await act(async () => buttonByLabel(node, en.Inbox.operationsPanel.cancel).click());

    expect(onCancel).toHaveBeenCalled();
    expect(cerrarOperacionManual).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
