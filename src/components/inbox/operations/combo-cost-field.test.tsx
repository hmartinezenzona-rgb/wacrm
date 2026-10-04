// @vitest-environment jsdom
// The owner/admin combo cost entry on a combo card (crm_set_combo_costo): a
// numeric input with save and clear, the saved value, and a "cost missing"
// hint once the combo is completed with no cost.

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

const setComboCosto = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  setComboCosto: (...args: unknown[]) => setComboCosto(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  setComboCosto.mockReset();
});

const t = en.Inbox.operationsPanel.comboCost;

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

async function render(props: { costGyd?: number | null; completed?: boolean; onSaved?: () => void } = {}) {
  const { ComboCostField } = await import("./combo-cost-field");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onSaved = props.onSaved ?? vi.fn();
  await act(async () =>
    root.render(
      <ComboCostField operationId="op-1" costGyd={props.costGyd ?? null} completed={props.completed ?? false} onSaved={onSaved} />,
    ),
  );
  return { node, root, onSaved };
}

const input = (node: Element) => node.querySelector<HTMLInputElement>("input")!;
const buttonByText = (node: Element, text: string) =>
  Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as HTMLButtonElement | undefined;

describe("ComboCostField", () => {
  it("labels the numeric input and starts empty with no hint on an open combo", async () => {
    const { node, root } = await render();

    expect(node.textContent).toContain(t.label);
    expect(input(node).value).toBe("");
    expect(input(node).getAttribute("inputmode")).toBe("decimal");
    expect(node.textContent).not.toContain(t.missing);
    expect(buttonByText(node, t.clear)).toBeUndefined();
    await act(async () => root.unmount());
  });

  it("shows the saved value, and a clear button", async () => {
    const { node, root } = await render({ costGyd: 18000 });

    expect(input(node).value).toBe("18000");
    expect(buttonByText(node, t.clear)).toBeDefined();
    expect(node.textContent).not.toContain(t.missing);
    await act(async () => root.unmount());
  });

  it("hints the missing cost on a completed combo without one, not when it has one", async () => {
    const missing = await render({ completed: true });
    expect(missing.node.textContent).toContain(t.missing);
    await act(async () => missing.root.unmount());
    document.body.replaceChildren();

    const priced = await render({ completed: true, costGyd: 100 });
    expect(priced.node.textContent).not.toContain(t.missing);
    await act(async () => priced.root.unmount());
  });

  it("saves the typed cost and tells the card", async () => {
    setComboCosto.mockResolvedValue({ ok: true, costGyd: 18000.5 });
    const { node, root, onSaved } = await render();

    await act(async () => setValue(input(node), "18000.5"));
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.save)!.click());

    expect(setComboCosto).toHaveBeenCalledWith("op-1", 18000.5);
    expect(onSaved).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it.each(["", "abc", "-5", "1000000000"])("rejects %j without a request", async (typed) => {
    const { node, root } = await render();

    await act(async () => setValue(input(node), typed));
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.save)!.click());

    expect(setComboCosto).not.toHaveBeenCalled();
    expect(node.textContent).toContain(t.invalid);
    await act(async () => root.unmount());
  });

  // Owner test 2026-10-04: costs are typed the way GYD amounts are written, with thousands separators.
  it.each([
    ["40,000", 40000],
    ["40.000", 40000],
    ["40 000", 40000],
    ["1,250,000", 1250000],
    ["40000", 40000],
    ["18000.5", 18000.5],
    ["18000,5", 18000.5],
  ])("reads %j as %d", async (typed, expected) => {
    setComboCosto.mockResolvedValue({ ok: true, costGyd: expected });
    const { node, root } = await render();

    await act(async () => setValue(input(node), typed));
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.save)!.click());

    expect(setComboCosto).toHaveBeenCalledWith("op-1", expected);
    await act(async () => root.unmount());
  });

  it("accepts zero", async () => {
    setComboCosto.mockResolvedValue({ ok: true, costGyd: 0 });
    const { node, root } = await render();

    await act(async () => setValue(input(node), "0"));
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.save)!.click());

    expect(setComboCosto).toHaveBeenCalledWith("op-1", 0);
    await act(async () => root.unmount());
  });

  it("clears the saved cost with null", async () => {
    setComboCosto.mockResolvedValue({ ok: true, costGyd: null });
    const { node, root, onSaved } = await render({ costGyd: 18000 });

    await act(async () => buttonByText(node, t.clear)!.click());

    expect(setComboCosto).toHaveBeenCalledWith("op-1", null);
    expect(onSaved).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server's message when the save fails and does not refresh", async () => {
    setComboCosto.mockResolvedValue({ ok: false, status: 403, error: "Forbidden" });
    const { node, root, onSaved } = await render();

    await act(async () => setValue(input(node), "100"));
    await act(async () => buttonByText(node, en.Inbox.operationsPanel.save)!.click());

    expect(node.textContent).toContain("Forbidden");
    expect(onSaved).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
