// @vitest-environment jsdom
// "Cerrar manualmente" for a whole mixed send: the existing per-operation manual close, once per member in order.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

const cerrarOperacionManual = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  cerrarOperacionManual: (...args: unknown[]) => cerrarOperacionManual(...args),
}));

const S = en.Inbox.operationsPanel.mixedSend;

beforeEach(() => vi.clearAllMocks());
afterEach(() => document.body.replaceChildren());

const byLabel = (label: string) =>
  Array.from(document.body.querySelectorAll("button")).find((b) => b.getAttribute("aria-label") === label) as HTMLButtonElement;

async function open(onDone = vi.fn(), onCancel = vi.fn()) {
  const { MixedCloseControl } = await import("./mixed-close-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<MixedCloseControl operationIds={["op-a", "op-b"]} onDone={onDone} onCancel={onCancel} />));
  return { root, onDone, onCancel };
}

describe("MixedCloseControl", () => {
  it("closes every member through the per-operation close, in order, with the bell off by default", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root, onDone } = await open();

    await act(async () => byLabel(S.closeConfirm).click());

    expect(cerrarOperacionManual.mock.calls).toEqual([["op-a", false], ["op-b", false]]);
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("passes the bell choice to every member", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root } = await open();

    await act(async () => document.body.querySelector<HTMLButtonElement>("button[aria-pressed]")!.click());
    await act(async () => byLabel(S.closeConfirm).click());

    expect(cerrarOperacionManual.mock.calls.map((call) => call[1])).toEqual([true, true]);
    await act(async () => root.unmount());
  });

  it("stops at the failing member, shows its reason and, on retry, closes only the members not closed", async () => {
    cerrarOperacionManual
      .mockResolvedValueOnce({ ok: true, newStatus: "completed", completedAt: "x" })
      .mockResolvedValueOnce({ ok: false, status: 400, error: "cannot close: holds a consumed deposit" })
      .mockResolvedValueOnce({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root, onDone } = await open();

    await act(async () => byLabel(S.closeConfirm).click());

    expect(cerrarOperacionManual.mock.calls.map((call) => call[0])).toEqual(["op-a", "op-b"]);
    expect(document.body.textContent).toContain("cannot close: holds a consumed deposit");
    expect(document.body.textContent).toContain(S.closeProgress.replace("{done}", "1").replace("{total}", "2"));
    expect(onDone).not.toHaveBeenCalled();

    await act(async () => byLabel(S.closeConfirm).click());

    expect(cerrarOperacionManual.mock.calls.map((call) => call[0])).toEqual(["op-a", "op-b", "op-b"]);
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("a member refused for an empty Clásica inventory shows the translated reason, not the machine code", async () => {
    cerrarOperacionManual.mockResolvedValueOnce({
      ok: false,
      status: 400,
      error: "usd_inventory_insufficient:CLASICA:50 (needs 50 USD, 0 USD available)",
    });
    const { root, onDone } = await open();

    await act(async () => byLabel(S.closeConfirm).click());

    const expected = en.Inbox.operationsPanel.completeTransfer.refusal.usdInventoryInsufficient
      .replace("{missing}", "50")
      .replace("{service}", "Clásica");
    expect(document.body.textContent).toContain(expected);
    expect(document.body.textContent).not.toContain("usd_inventory_insufficient");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancels from the X without closing anything", async () => {
    const { root, onCancel } = await open();

    await act(async () => byLabel(en.Inbox.operationsPanel.cancel).click());

    expect(cerrarOperacionManual).not.toHaveBeenCalled();
    expect(onCancel).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });
});
