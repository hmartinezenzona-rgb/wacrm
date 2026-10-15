// @vitest-environment jsdom
// Spec: per-beneficiary delivery proof (P3). `CompleteTransferMultiSection`
// is the 2+-beneficiary counterpart to `CompleteTransferSection`: one
// `DeliveryProofPanel` per current beneficiary, captions only on the
// Zelle ones, and a single skip-screenshot checkbox + submit row shared
// by the whole operation (never per beneficiary).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { CompleteTransferMultiSection, type CompleteTransferProofItem } from "./complete-transfer-multi-section";

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

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const T = en.Inbox.operationsPanel.completeTransfer;

function item(over: Partial<CompleteTransferProofItem> = {}): CompleteTransferProofItem {
  return {
    beneficiaryId: over.beneficiaryId ?? "ben-1",
    label: over.label ?? "Beneficiary 1",
    showCaption: false,
    file: null,
    previewUrl: null,
    caption: "",
    onFileAccepted: vi.fn(),
    onFileRejected: vi.fn(),
    onCaptionChange: vi.fn(),
    onClear: vi.fn(),
    ...over,
  };
}

async function render(overrides: Partial<Parameters<typeof CompleteTransferMultiSection>[0]> = {}) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <CompleteTransferMultiSection
        items={[item({ beneficiaryId: "ben-1", label: "Beneficiary 1" }), item({ beneficiaryId: "ben-2", label: "Beneficiary 2" })]}
        skipChecked={false}
        onSkipChange={vi.fn()}
        busy={false}
        canSend={true}
        canSubmit={true}
        banner={null}
        onCancel={vi.fn()}
        onSubmit={vi.fn()}
        {...overrides}
      />,
    ),
  );
  return { node, root };
}

describe("CompleteTransferMultiSection", () => {
  it("renders one drop zone per beneficiary", async () => {
    const { node, root } = await render();

    const dropZones = node.querySelectorAll('[role="button"]');
    expect(dropZones.length).toBe(2);
    expect(node.textContent).toContain("Beneficiary 1");
    expect(node.textContent).toContain("Beneficiary 2");
    await act(async () => root.unmount());
  });

  it("shows the caption box only for the Zelle beneficiaries once a file is attached", async () => {
    const { node, root } = await render({
      items: [
        item({ beneficiaryId: "ben-1", label: "Beneficiary 1", showCaption: true, file: new File(["x"], "a.png") }),
        item({ beneficiaryId: "ben-2", label: "Beneficiary 2", showCaption: false, file: new File(["x"], "b.png") }),
      ],
    });

    expect(node.querySelectorAll("textarea").length).toBe(1);
    await act(async () => root.unmount());
  });

  it("keeps the withoutScreenshot checkbox and submit/cancel controls shared, not per beneficiary", async () => {
    const { node, root } = await render();

    expect(node.querySelectorAll('input[type="checkbox"]').length).toBe(1);
    expect(node.textContent).toContain(T.withoutScreenshot);
    await act(async () => root.unmount());
  });

  it("disables submit when canSubmit is false", async () => {
    const { node, root } = await render({ canSubmit: false });

    const submit = Array.from(node.querySelectorAll("button")).find(
      (b) => (b.textContent?.trim() || b.getAttribute("aria-label")) === T.sendAndComplete || (b.textContent?.trim() || b.getAttribute("aria-label")) === T.complete,
    ) as HTMLButtonElement;
    expect(submit.disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("calls onSubmit when the submit button is clicked and enabled", async () => {
    const onSubmit = vi.fn();
    const { node, root } = await render({ onSubmit, canSubmit: true });

    const submit = Array.from(node.querySelectorAll("button")).find(
      (b) => (b.textContent?.trim() || b.getAttribute("aria-label")) === T.sendAndComplete || (b.textContent?.trim() || b.getAttribute("aria-label")) === T.complete,
    ) as HTMLButtonElement;
    await act(async () => submit.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onSubmit).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("shows the banner text and its retry action when present", async () => {
    const onClick = vi.fn();
    const { node, root } = await render({
      banner: { kind: "error", text: "Could not send", action: { label: T.retry, onClick } },
    });

    expect(node.textContent).toContain("Could not send");
    const retry = Array.from(node.querySelectorAll("button")).find((b) => (b.textContent?.trim() || b.getAttribute("aria-label")) === T.retry) as HTMLButtonElement;
    await act(async () => retry.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    expect(onClick).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });
});

describe("CompleteTransferMultiSection extra slot", () => {
  it("renders the extra block under the title, and nothing when it is absent", async () => {
    const withExtra = await render({ extra: <div data-testid="extra-block">plan</div> });
    expect(withExtra.node.querySelector('[data-testid="extra-block"]')).not.toBeNull();
    const without = await render();
    expect(without.node.querySelector('[data-testid="extra-block"]')).toBeNull();
  });
});
