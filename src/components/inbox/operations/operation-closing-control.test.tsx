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

// The real block fetches the plan and renders nothing for non-CUP operations; here it is a stub that exposes its props.
vi.mock("./cup-plan-block", () => ({
  CupPlanBlock: ({ operationId, sourceCardId, onSourceCardChange }: { operationId: string; sourceCardId: string | null; onSourceCardChange: (id: string | null) => void }) => (
    <button type="button" data-testid="cup-plan-stub" data-operation={operationId} data-source={sourceCardId ?? ""} onClick={() => onSourceCardChange("card-9")} />
  ),
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

async function render(
  kind: "close" | "delete",
  onDone = vi.fn(),
  onCancel = vi.fn(),
  needsService?: boolean,
) {
  const { OperationClosingControl } = await import("./operation-closing-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <OperationClosingControl
        operationId="op-1"
        kind={kind}
        onDone={onDone}
        onCancel={onCancel}
        needsService={needsService}
      />,
    ),
  );
  return { node, root, onDone, onCancel };
}

// The picker names its options with the shared service names (src/lib/service-name.ts).
const SERVICE_LABELS = {
  cuban_card: en.ServiceNames.cup, zelle: en.ServiceNames.zelle, clasica: en.ServiceNames.clasica,
  tropical: en.ServiceNames.tropical, efectivo_usd: en.ServiceNames.efectivo_usd, recarga: en.ServiceNames.recarga,
  combo: en.ServiceNames.combo, visa: en.ServiceNames.visa, saldo: en.ServiceNames.saldo,
};

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
    expect(confirm.className).toContain("emerald");
    await act(async () => root.unmount());
  });

  it("close: confirm sends notify=false by default (bell off) and no reason, then onDone", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root, onDone } = await render("close");

    expect(node.textContent).toBe(""); // no explanatory text (owner, 2026-10-03)
    const bell = node.querySelector<HTMLButtonElement>("button[aria-pressed]")!;
    expect(bell.getAttribute("aria-pressed")).toBe("false");
    expect(bell.getAttribute("aria-label")).toBe(en.Inbox.operationsPanel.notify.off);

    await act(async () => buttonByLabel(node, t.closeConfirm).click());

    expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false);
    expect(eliminarOperacion).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("close: shows the CUP plan block with the source-card picker for the operation", async () => {
    const { node, root } = await render("close");

    const block = node.querySelector<HTMLElement>("[data-testid=cup-plan-stub]")!;
    expect(block).not.toBeNull();
    expect(block.dataset.operation).toBe("op-1");
    await act(async () => root.unmount());
  });

  it("close: choosing a source card sends cupSourceCardId with the close", async () => {
    cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root } = await render("close");

    await act(async () => node.querySelector<HTMLButtonElement>("[data-testid=cup-plan-stub]")!.click());
    expect(node.querySelector<HTMLElement>("[data-testid=cup-plan-stub]")!.dataset.source).toBe("card-9");
    await act(async () => buttonByLabel(node, t.closeConfirm).click());

    expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false, undefined, "card-9");
    await act(async () => root.unmount());
  });

  it("delete: does not show the CUP plan block", async () => {
    const { node, root } = await render("delete");
    expect(node.querySelector("[data-testid=cup-plan-stub]")).toBeNull();
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

    expect(node.textContent).toBe(""); // no explanatory text (owner, 2026-10-03)
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

  describe("service picker (no beneficiary and no delivery method)", () => {
    const m = SERVICE_LABELS;
    const labels = [m.cuban_card, m.zelle, m.clasica, m.tropical, m.efectivo_usd, m.recarga, m.combo, m.visa, m.saldo];

    it("shows nine single-select icon buttons and keeps the check disabled until one is picked", async () => {
      const { node, root } = await render("close", vi.fn(), vi.fn(), true);

      for (const label of labels) {
        const b = buttonByLabel(node, label);
        expect(b).not.toBeNull();
        expect(b.title).toBe(label);
        expect(b.getAttribute("aria-pressed")).toBe("false");
        expect(b.querySelector('[role="img"]')).not.toBeNull(); // icon, not a text label
      }
      expect(buttonByLabel(node, t.closeConfirm).disabled).toBe(true);

      await act(async () => buttonByLabel(node, m.zelle).click());
      expect(buttonByLabel(node, m.zelle).getAttribute("aria-pressed")).toBe("true");
      expect(buttonByLabel(node, m.cuban_card).getAttribute("aria-pressed")).toBe("false");
      expect(buttonByLabel(node, t.closeConfirm).disabled).toBe(false);

      await act(async () => buttonByLabel(node, m.tropical).click());
      expect(buttonByLabel(node, m.zelle).getAttribute("aria-pressed")).toBe("false");
      expect(buttonByLabel(node, m.tropical).getAttribute("aria-pressed")).toBe("true");
      await act(async () => root.unmount());
    });

    it("confirm sends the chosen method and the bell value", async () => {
      cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
      const { node, root, onDone } = await render("close", vi.fn(), vi.fn(), true);

      await act(async () => buttonByLabel(node, m.efectivo_usd).click());
      await act(async () => buttonByLabel(node, en.Inbox.operationsPanel.notify.off).click());
      await act(async () => buttonByLabel(node, t.closeConfirm).click());

      expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", true, "efectivo_usd");
      expect(onDone).toHaveBeenCalled();
      await act(async () => root.unmount());
    });

    it("Recharge confirms with deliveryMethod recarga", async () => {
      cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
      const { node, root } = await render("close", vi.fn(), vi.fn(), true);

      expect(m.recarga).toBe("Top-up");
      await act(async () => buttonByLabel(node, m.recarga).click());
      await act(async () => buttonByLabel(node, t.closeConfirm).click());

      expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false, "recarga");
      await act(async () => root.unmount());
    });

    it("Combo confirms with deliveryMethod combo", async () => {
      cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
      const { node, root } = await render("close", vi.fn(), vi.fn(), true);

      expect(m.combo).toBe("Combo");
      await act(async () => buttonByLabel(node, m.combo).click());
      await act(async () => buttonByLabel(node, t.closeConfirm).click());

      expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false, "combo");
      await act(async () => root.unmount());
    });

    it("Visa confirms with deliveryMethod visa", async () => {
      cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
      const { node, root } = await render("close", vi.fn(), vi.fn(), true);

      expect(m.visa).toBe("Visa");
      await act(async () => buttonByLabel(node, m.visa).click());
      await act(async () => buttonByLabel(node, t.closeConfirm).click());

      expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false, "visa");
      await act(async () => root.unmount());
    });

    it("Mobile balance confirms with deliveryMethod saldo, with an icon of its own", async () => {
      cerrarOperacionManual.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
      const { node, root } = await render("close", vi.fn(), vi.fn(), true);

      expect(m.saldo).toBe("Mobile balance");
      expect(buttonByLabel(node, m.saldo).querySelector("svg.lucide-coins")).not.toBeNull();
      expect(buttonByLabel(node, m.recarga).querySelector("svg.lucide-coins")).toBeNull();
      await act(async () => buttonByLabel(node, m.saldo).click());
      await act(async () => buttonByLabel(node, t.closeConfirm).click());

      expect(cerrarOperacionManual).toHaveBeenCalledWith("op-1", false, "saldo");
      await act(async () => root.unmount());
    });

    it("shows no icons for delete, nor for close when a beneficiary or method exists", async () => {
      for (const [kind, needs] of [["delete", true], ["close", false], ["close", undefined]] as const) {
        const { node, root } = await render(kind, vi.fn(), vi.fn(), needs);
        for (const label of labels) expect(buttonByLabel(node, label)).toBeNull();
        await act(async () => root.unmount());
        document.body.replaceChildren();
      }
    });
  });
});

describe("OperationClosingControl service icons are told apart", () => {
  it("draws a different icon for each of the nine services", async () => {
    const { node, root } = await render("close", vi.fn(), vi.fn(), true);
    const icons = Object.values(SERVICE_LABELS).map((label) => {
      const svg = buttonByLabel(node, label)?.querySelector("svg");
      return svg?.getAttribute("class") ?? "";
    });

    expect(icons).toHaveLength(9);
    expect(new Set(icons).size).toBe(9);
    await act(async () => root.unmount());
  });

  it("is an unboxed area and Escape on a control cancels", async () => {
    const { node, root, onCancel } = await render("close");

    expect(node.firstElementChild!.className).not.toContain("bg-muted");
    await act(async () =>
      buttonByLabel(node, t.closeConfirm).dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      ),
    );
    expect(onCancel).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  describe.each([
    ["an operation that is cancelled cannot be deleted", 400, "alreadyClosed"],
    ["an operation that is completed cannot be deleted", 400, "alreadyClosed"],
    ["an operation with a verified deposit cannot be deleted", 400, "verifiedDeposit"],
    ["only an owner or admin can delete an operation", 400, "notAdmin"],
    ["Forbidden", 403, "notAdmin"],
  ] as const)("a refused delete (%s)", (message, status, key) => {
    it("shows the Spanish-keyed reason and keeps the form open", async () => {
      eliminarOperacion.mockResolvedValueOnce({ ok: false, status, error: message });
      const { node, onDone } = await render("delete");

      await act(async () => buttonByLabel(node, t.deleteConfirm).click());

      expect(node.textContent).toContain(t.deleteRefusal[key]);
      expect(onDone).not.toHaveBeenCalled();
    });
  });

  it("shows the server text when a refused delete is not a known reason", async () => {
    eliminarOperacion.mockResolvedValueOnce({ ok: false, status: 400, error: "an operation that is transferring cannot be deleted" });
    const { node } = await render("delete");

    await act(async () => buttonByLabel(node, t.deleteConfirm).click());

    expect(node.textContent).toContain("an operation that is transferring cannot be deleted");
  });
});
