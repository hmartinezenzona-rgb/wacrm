// @vitest-environment jsdom
// Spec: odd/tasks/remesa-closing-and-cash.md (E2). The bell that decides
// whether a panel action messages the customer: pressed = on.

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

const copy = en.Inbox.operationsPanel.notify;

async function render(notify: boolean, onChange = vi.fn(), disabled = false) {
  const { NotifyToggle } = await import("./notify-toggle");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<NotifyToggle notify={notify} onChange={onChange} disabled={disabled} />));
  return { node, root, onChange, button: node.querySelector("button")! };
}

describe("NotifyToggle", () => {
  it("on: pressed, labelled as on, shows a Bell icon", async () => {
    const { button, root } = await render(true);

    expect(button.getAttribute("aria-pressed")).toBe("true");
    expect(button.getAttribute("aria-label")).toBe(copy.on);
    expect(button.title).toBe(copy.on);
    expect(button.querySelector("svg")?.getAttribute("class")).toContain("lucide-bell");
    expect(button.querySelector("svg")?.getAttribute("class")).not.toContain("lucide-bell-off");
    await act(async () => root.unmount());
  });

  it("off: not pressed, labelled as off, shows a BellOff icon", async () => {
    const { button, root } = await render(false);

    expect(button.getAttribute("aria-pressed")).toBe("false");
    expect(button.getAttribute("aria-label")).toBe(copy.off);
    expect(button.querySelector("svg")?.getAttribute("class")).toContain("lucide-bell-off");
    await act(async () => root.unmount());
  });

  it("clicking asks for the opposite value", async () => {
    const { button, onChange, root } = await render(true);

    await act(async () => button.click());

    expect(onChange).toHaveBeenCalledWith(false);
    await act(async () => root.unmount());
  });

  it("disabled does not fire", async () => {
    const { button, onChange, root } = await render(true, vi.fn(), true);

    await act(async () => button.click());

    expect(onChange).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
