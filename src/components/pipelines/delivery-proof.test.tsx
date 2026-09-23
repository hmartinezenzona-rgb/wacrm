// @vitest-environment jsdom
// Covers the `showCaption` prop added for panel-23: the operations-panel
// "Complete transfer" section reuses this panel but only wants the note
// textarea for Zelle transfers. Default (omitted) keeps the pipelines
// board's existing behaviour — the textarea always shows alongside a
// chosen file.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import { DeliveryProofPanel } from "./delivery-proof";

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

function pngFile(): File {
  return new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "capture.png", { type: "image/png" });
}

interface RenderOptions {
  showCaption?: boolean;
}

async function render(options: RenderOptions = {}) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <DeliveryProofPanel
        file={pngFile()}
        previewUrl="blob:test"
        caption=""
        onFileAccepted={vi.fn()}
        onFileRejected={vi.fn()}
        onCaptionChange={vi.fn()}
        onClear={vi.fn()}
        window={null}
        showCaption={options.showCaption}
      />,
    ),
  );
  return { node, root };
}

describe("DeliveryProofPanel showCaption", () => {
  it("shows the note textarea by default (pipelines board is unchanged)", async () => {
    const { node, root } = await render();
    expect(node.querySelector("textarea")).not.toBeNull();
    expect(node.textContent).toContain(en.Pipelines.deliveryProof.noteLabel);
    await act(async () => root.unmount());
  });

  it("hides the note textarea when showCaption is false", async () => {
    const { node, root } = await render({ showCaption: false });
    expect(node.querySelector("textarea")).toBeNull();
    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.noteLabel);
    await act(async () => root.unmount());
  });

  it("shows the note textarea when showCaption is explicitly true", async () => {
    const { node, root } = await render({ showCaption: true });
    expect(node.querySelector("textarea")).not.toBeNull();
    await act(async () => root.unmount());
  });
});

// panel-26: the operations panel's "Complete transfer" section reuses this
// same panel in a denser, English-labeled shape — no outer bordered box, a
// full-width drop zone, and a single round remove button on the thumbnail
// instead of "Change"/"Remove" text buttons. The default (pipelines board)
// variant/markup must stay exactly as tested above.
describe("DeliveryProofPanel compact variant", () => {
  const LABELS = {
    dropHint: "Paste (Ctrl+V), drop or choose a screenshot",
    dropFormats: "PNG · JPG · WEBP · max 5 MB",
    removeAria: "Remove screenshot",
  };

  interface CompactRenderOptions {
    file?: File | null;
    previewUrl?: string | null;
    onClear?: () => void;
  }

  async function renderCompact(options: CompactRenderOptions = {}) {
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    const onClear = options.onClear ?? vi.fn();
    await act(async () =>
      root.render(
        <DeliveryProofPanel
          file={options.file === undefined ? pngFile() : options.file}
          previewUrl={options.previewUrl === undefined ? "blob:test" : options.previewUrl}
          caption=""
          onFileAccepted={vi.fn()}
          onFileRejected={vi.fn()}
          onCaptionChange={vi.fn()}
          onClear={onClear}
          window={null}
          variant="compact"
          labels={LABELS}
        />,
      ),
    );
    return { node, root, onClear };
  }

  it("shows the overridden English hint instead of the default two-line Spanish copy", async () => {
    const { node, root } = await renderCompact({ file: null, previewUrl: null });

    expect(node.textContent).toContain(LABELS.dropHint);
    expect(node.textContent).toContain(LABELS.dropFormats);
    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.dropPaste);
    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.dropOr);
    await act(async () => root.unmount());
  });

  it("does not render the outer bordered box", async () => {
    const { node, root } = await renderCompact({ file: null, previewUrl: null });

    const outer = node.firstElementChild as HTMLElement;
    expect(outer.className).not.toContain("border");
    await act(async () => root.unmount());
  });

  it("renders a single round remove button (no Change/Remove text buttons) when a file is attached", async () => {
    const { node, root } = await renderCompact();

    const removeButton = node.querySelector(`button[aria-label="${LABELS.removeAria}"]`);
    expect(removeButton).not.toBeNull();
    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.change);
    expect(node.textContent).not.toContain(en.Pipelines.deliveryProof.remove);
    await act(async () => root.unmount());
  });

  it("the remove button calls onClear", async () => {
    const onClear = vi.fn();
    const { node, root } = await renderCompact({ onClear });

    const removeButton = node.querySelector(`button[aria-label="${LABELS.removeAria}"]`) as HTMLButtonElement;
    await act(async () => removeButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onClear).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });
});
