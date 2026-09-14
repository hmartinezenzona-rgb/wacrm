// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel beneficiary data rows — a small
// icon-only button that copies one raw value (card, phone, zelle account,
// name) to the clipboard and shows a brief "copied" state.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CopyButton } from "./copy-button";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
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

describe("CopyButton", () => {
  it("copies the exact value and switches to the copied state", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    stubClipboard(writeText);

    const { node, root } = await renderNode(<CopyButton value="9205123412349412" ariaLabel="Copy Card" />);
    const button = node.querySelector("button")!;
    expect(button.getAttribute("aria-label")).toBe("Copy Card");
    expect(button.getAttribute("data-copied")).toBe("false");

    await act(async () => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(writeText).toHaveBeenCalledWith("9205123412349412");
    expect(button.getAttribute("data-copied")).toBe("true");
    await act(async () => root.unmount());
  });

  it("leaves data-copied false and throws nothing when the clipboard write is rejected", async () => {
    const writeText = vi.fn().mockRejectedValue(new Error("denied"));
    stubClipboard(writeText);

    const { node, root } = await renderNode(<CopyButton value="5355551111" ariaLabel="Copy Phone" />);
    const button = node.querySelector("button")!;

    await act(async () => {
      button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(button.getAttribute("data-copied")).toBe("false");
    await act(async () => root.unmount());
  });
});
