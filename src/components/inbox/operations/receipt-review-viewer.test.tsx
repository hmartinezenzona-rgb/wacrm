// @vitest-environment jsdom
// Ported from the Hermes reference receipt viewer, with its copy logic
// (i18n instead of hardcoded Spanish) and the `{ src, alt }` prop contract
// used by the panel-19 deposit review block. Covers the parts that are
// this repo's responsibility, not already covered by viewer-geometry.test.ts:
// it renders the given image, the zoom-in control increases the visible
// percentage, and reset returns it to 100%.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { ReceiptReviewViewer } from "./receipt-review-viewer";

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
});

async function renderNode(element: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(element));
  return { node, root };
}

const T = en.Inbox.operationsPanel.viewer;

describe("ReceiptReviewViewer", () => {
  it("renders the given image with its src and alt", async () => {
    const { node, root } = await renderNode(
      <ReceiptReviewViewer src="https://example.test/comp-1.jpg" alt="Deposit receipt" />,
    );

    const img = node.querySelector("img")!;
    expect(img.getAttribute("src")).toBe("https://example.test/comp-1.jpg");
    expect(img.getAttribute("alt")).toBe("Deposit receipt");
    await act(async () => root.unmount());
  });

  it("starts at 100% and zooming in increases the visible percentage", async () => {
    const { node, root } = await renderNode(
      <ReceiptReviewViewer src="https://example.test/comp-1.jpg" alt="Deposit receipt" />,
    );

    expect(node.textContent).toContain("100%");

    const zoomIn = node.querySelector(`button[aria-label="${T.zoomIn}"]`)!;
    await act(async () => zoomIn.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(node.textContent).not.toContain("100%");
    expect(node.textContent).toContain("125%");
    await act(async () => root.unmount());
  });

  it("reset returns the zoom to 100%", async () => {
    const { node, root } = await renderNode(
      <ReceiptReviewViewer src="https://example.test/comp-1.jpg" alt="Deposit receipt" />,
    );

    const zoomIn = node.querySelector(`button[aria-label="${T.zoomIn}"]`)!;
    await act(async () => zoomIn.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    expect(node.textContent).toContain("125%");

    const reset = node.querySelector(`button[aria-label="${T.reset}"]`)!;
    await act(async () => reset.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(node.textContent).toContain("100%");
    await act(async () => root.unmount());
  });

  it("exposes the accessible zoom-out and viewer-hint labels", async () => {
    const { node, root } = await renderNode(
      <ReceiptReviewViewer src="https://example.test/comp-1.jpg" alt="Deposit receipt" />,
    );

    expect(node.querySelector(`button[aria-label="${T.zoomOut}"]`)).not.toBeNull();
    expect(node.querySelector(`[aria-label="${T.hint}"]`)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("shows a public chat-media URL through the same-origin proxy", async () => {
    const acct = "3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c";
    const { node, root } = await renderNode(
      <ReceiptReviewViewer
        src={`https://abc.supabase.co/storage/v1/object/public/chat-media/account-${acct}/1-wa-1.jpg`}
        alt="Deposit receipt"
      />,
    );

    expect(node.querySelector("img")!.getAttribute("src")).toBe(
      `/api/chat-media/account-${acct}/1-wa-1.jpg`,
    );
    await act(async () => root.unmount());
  });
});
