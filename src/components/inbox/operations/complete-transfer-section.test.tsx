// @vitest-environment jsdom
// Spec: panel-26 proof attach UX. `CompleteTransferSection` wires the
// shared `DeliveryProofPanel` in its compact, English-labeled shape (no
// outer bordered box, full-width drop zone, single round remove button) —
// covered end to end here by rendering the real panel (not mocked) and
// checking the English copy/labels reach it, rather than re-testing the
// panel's own compact-variant behavior (delivery-proof.test.tsx).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { CompleteTransferSection } from "./complete-transfer-section";

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

const PROOF = en.Inbox.operationsPanel.completeTransfer.proof;

async function render(overrides: Partial<Parameters<typeof CompleteTransferSection>[0]> = {}) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <CompleteTransferSection
        showCaption={false}
        file={null}
        previewUrl={null}
        caption=""
        onFileAccepted={vi.fn()}
        onFileRejected={vi.fn()}
        onCaptionChange={vi.fn()}
        onClear={vi.fn()}
        skipChecked={false}
        onSkipChange={vi.fn()}
        busy={false}
        canSend={true}
        banner={null}
        onCancel={vi.fn()}
        onSubmit={vi.fn()}
        {...overrides}
      />,
    ),
  );
  return { node, root };
}

describe("CompleteTransferSection proof attach (compact)", () => {
  it("shows the English compact drop hint instead of the pipelines board's Spanish copy", async () => {
    const { node, root } = await render();

    expect(node.textContent).toContain(PROOF.dropHint);
    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.dropPaste);
    await act(async () => root.unmount());
  });

  it("does not render the shared panel's own bordered wrapper/title (avoids a duplicate title)", async () => {
    const { node, root } = await render();

    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.title);
    await act(async () => root.unmount());
  });
});

describe("CompleteTransferSection helper follows the notify bell", () => {
  const CT = en.Inbox.operationsPanel.completeTransfer;

  it("says the customer gets the completed message while the bell is on", async () => {
    const { node, root } = await render({ notify: true, onNotifyChange: vi.fn() });

    expect(node.textContent).toContain(CT.helper);
    await act(async () => root.unmount());
  });

  it("says only the screenshot goes out while the bell is off", async () => {
    const { node, root } = await render({ notify: false, onNotifyChange: vi.fn() });

    expect(node.textContent).toContain(CT.helperSilent);
    expect(node.textContent).not.toContain(CT.helper);
    await act(async () => root.unmount());
  });
});
