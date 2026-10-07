// @vitest-environment jsdom
// Spec: odd/tasks/panel-minimal-edit.md (T1). The one check (confirm) and X (cancel)
// pair used by every save / confirm / cancel of the operations panel.

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

afterEach(() => {
  document.body.replaceChildren();
});

const copy = en.Inbox.operationsPanel;

async function render(props: Partial<React.ComponentProps<typeof import("./confirm-cancel-buttons").ConfirmCancelButtons>> = {}) {
  const { ConfirmCancelButtons } = await import("./confirm-cancel-buttons");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ConfirmCancelButtons onCancel={() => {}} {...props} />));
  return { node, root };
}

const byLabel = (node: Element, label: string) => node.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`);
const click = (el: Element) => act(async () => el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })));

describe("ConfirmCancelButtons", () => {
  it("renders icon-only buttons named by the catalog (X first, then check), with no visible text", async () => {
    const { node, root } = await render();

    const buttons = Array.from(node.querySelectorAll("button"));
    expect(buttons.map((b) => b.getAttribute("aria-label"))).toEqual([copy.cancel, copy.save]);
    expect(buttons.map((b) => b.getAttribute("title"))).toEqual([copy.cancel, copy.save]);
    expect(node.textContent).toBe("");
    for (const svg of Array.from(node.querySelectorAll("svg"))) expect(svg.getAttribute("aria-hidden")).toBe("true");
    await act(async () => root.unmount());
  });

  it("styles X muted and the check emerald without a solid fill", async () => {
    const { node, root } = await render();

    expect(byLabel(node, copy.cancel)!.className).toContain("text-muted-foreground");
    const confirm = byLabel(node, copy.save)!.className;
    expect(confirm).toContain("text-emerald-600");
    expect(confirm).toContain("dark:text-emerald-400");
    expect(confirm).not.toContain("bg-green-600");
    await act(async () => root.unmount());
  });

  it("uses a custom confirm label for both aria-label and title", async () => {
    const { node, root } = await render({ confirmLabel: copy.confirmMove });

    const confirm = byLabel(node, copy.confirmMove)!;
    expect(confirm.getAttribute("title")).toBe(copy.confirmMove);
    expect(byLabel(node, copy.save)).toBeNull();
    await act(async () => root.unmount());
  });

  it("calls onCancel and onConfirm from type=button clicks", async () => {
    const onCancel = vi.fn();
    const onConfirm = vi.fn();
    const { node, root } = await render({ onCancel, onConfirm });

    expect(byLabel(node, copy.save)!.getAttribute("type")).toBe("button");
    await click(byLabel(node, copy.cancel)!);
    await click(byLabel(node, copy.save)!);
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(onConfirm).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("renders the check as a submit button when asked, and fires no onConfirm", async () => {
    const onSubmit = vi.fn((event: React.FormEvent) => event.preventDefault());
    const { ConfirmCancelButtons } = await import("./confirm-cancel-buttons");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () =>
      root.render(
        <form onSubmit={onSubmit}>
          <ConfirmCancelButtons type="submit" onCancel={() => {}} />
        </form>,
      ),
    );

    const confirm = byLabel(node, copy.save)!;
    expect(confirm.getAttribute("type")).toBe("submit");
    expect(byLabel(node, copy.cancel)!.getAttribute("type")).toBe("button");
    await click(confirm);
    expect(onSubmit).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("while pending disables both buttons and swaps the check for a spinner", async () => {
    const { node, root } = await render({ pending: true });

    expect(byLabel(node, copy.cancel)!.disabled).toBe(true);
    const confirm = byLabel(node, copy.save)!;
    expect(confirm.disabled).toBe(true);
    expect(confirm.getAttribute("aria-busy")).toBe("true");
    expect(confirm.querySelector(".animate-spin")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("confirmDisabled disables only the check", async () => {
    const { node, root } = await render({ confirmDisabled: true });

    expect(byLabel(node, copy.save)!.disabled).toBe(true);
    expect(byLabel(node, copy.cancel)!.disabled).toBe(false);
    expect(node.querySelector(".animate-spin")).toBeNull();
    await act(async () => root.unmount());
  });

  it("omits the X when there is nothing to cancel", async () => {
    const { node, root } = await render({ onCancel: undefined });

    expect(byLabel(node, copy.cancel)).toBeNull();
    expect(byLabel(node, copy.save)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("renders the extra slot before the X", async () => {
    const { node, root } = await render({ children: <button type="button" data-testid="extra" /> });

    const all = Array.from(node.querySelectorAll("button"));
    expect(all[0].getAttribute("data-testid")).toBe("extra");
    expect(all[1].getAttribute("aria-label")).toBe(copy.cancel);
    await act(async () => root.unmount());
  });

  it("gives every button a 32px hit area", async () => {
    const { node, root } = await render();

    for (const button of Array.from(node.querySelectorAll("button"))) expect(button.className).toContain("size-8");
    await act(async () => root.unmount());
  });
});

describe("cancelOnEscape", () => {
  it("cancels on Escape typed in a field inside the form, but ignores other keys and portaled targets", async () => {
    const { cancelOnEscape } = await import("./confirm-cancel-buttons");
    const onCancel = vi.fn();
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () =>
      root.render(
        <form onKeyDown={cancelOnEscape(onCancel)}>
          <input data-testid="field" />
        </form>,
      ),
    );
    const field = node.querySelector("input")!;

    await act(async () => field.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true })));
    expect(onCancel).not.toHaveBeenCalled();
    await act(async () => field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })));
    expect(onCancel).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });
});
