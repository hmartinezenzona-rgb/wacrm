// @vitest-environment jsdom
// Spec: panel-19 operation-card redesign. CopyChip is the full-width
// tap-to-copy row used throughout the "Deliver to" block: by default it
// copies `value` to the clipboard and shows a transient "Copied ✓" state;
// when `onActivate` is given it instead calls that handler (e.g. the
// "Amount missing" warning chip opens the correction form) and never
// touches the clipboard. `tone="warning"` and `disabled` are purely
// presentational/interaction gates.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { CopyChip } from "./copy-chip";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

async function renderNode(element: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(element));
  return { node, root };
}

function stubClipboard(writeText: (value: string) => Promise<void>) {
  Object.defineProperty(navigator, "clipboard", {
    value: { writeText },
    configurable: true,
  });
}

describe("CopyChip", () => {
  it("copies the exact value to the clipboard on click", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    stubClipboard(writeText);

    const { node, root } = await renderNode(
      <CopyChip value="9205123412349412" ariaLabel="Copy Card" />,
    );
    const button = node.querySelector("button")!;

    await act(async () => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(writeText).toHaveBeenCalledWith("9205123412349412");
    await act(async () => root.unmount());
  });

  it("shows Copied then reverts to the display after 1200ms", async () => {
    vi.useFakeTimers();
    const writeText = vi.fn().mockResolvedValue(undefined);
    stubClipboard(writeText);

    const { node, root } = await renderNode(<CopyChip value="123" ariaLabel="Copy X" />);
    const button = node.querySelector("button")!;

    await act(async () => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(node.textContent).toContain(en.Inbox.operationsPanel.copied);
    const live = node.querySelector('[aria-live="polite"]');
    expect(live).not.toBeNull();

    await act(async () => {
      vi.advanceTimersByTime(1200);
    });

    expect(node.textContent).not.toContain(en.Inbox.operationsPanel.copied);
    expect(node.textContent).toContain("123");
    await act(async () => root.unmount());
  });

  it("calls onActivate instead of copying when provided", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    stubClipboard(writeText);
    const onActivate = vi.fn();

    const { node, root } = await renderNode(
      <CopyChip value="9205123412349412" ariaLabel="Add amount" onActivate={onActivate} />,
    );
    const button = node.querySelector("button")!;

    await act(async () => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onActivate).toHaveBeenCalledTimes(1);
    expect(writeText).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("renders with the warning tone marker", async () => {
    const { node, root } = await renderNode(
      <CopyChip value="missing" ariaLabel="Add amount" tone="warning" />,
    );
    const button = node.querySelector("button")!;

    expect(button.getAttribute("data-tone")).toBe("warning");
    await act(async () => root.unmount());
  });

  it("is inert when disabled: no click handler fires", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    stubClipboard(writeText);
    const onActivate = vi.fn();

    const { node, root } = await renderNode(
      <CopyChip value="missing" ariaLabel="Add amount" onActivate={onActivate} disabled />,
    );
    const button = node.querySelector("button")! as HTMLButtonElement;
    expect(button.disabled).toBe(true);

    await act(async () => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onActivate).not.toHaveBeenCalled();
    expect(writeText).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
