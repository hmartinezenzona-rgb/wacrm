// @vitest-environment jsdom
// Spec: panel-fully-editable T3a. Attaching an image of the chat as a receipt of the operation: the existing chat-image picker, one request to
// adjuntarComprobante with the chosen image, a note saying whether the reference and amount came from the image's reading, the refusal shown.

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

const adjuntarComprobante = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  adjuntarComprobante: (...args: unknown[]) => adjuntarComprobante(...args),
}));

// The picker owns its dialog and its fetch (id-photo-picker.test.tsx); here it is a button that "chooses" a fixed image and shows what the
// control passes down.
vi.mock("./id-photo-picker", () => ({
  IdPhotoPicker: ({ conversationId, label, disabled, onPick }: { conversationId: string; label: string; disabled?: boolean; onPick: (wamid: string) => void }) => (
    <button type="button" data-testid="picker" data-conversation={conversationId} disabled={disabled} onClick={() => onPick("wamid.ELEGIDA")}>
      {label}
    </button>
  ),
}));

afterEach(() => {
  document.body.replaceChildren();
  adjuntarComprobante.mockReset();
});

const A = en.Inbox.operationsPanel.attachReceipt;

async function render(onAttached = vi.fn()) {
  const { AttachReceiptControl } = await import("./attach-receipt-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<AttachReceiptControl operationId="op-1" conversationId="conv-1" onAttached={onAttached} />));
  return { node, root, onAttached };
}

const picker = (node: HTMLElement) => node.querySelector<HTMLButtonElement>('[data-testid="picker"]')!;
const pickImage = (node: HTMLElement) => act(async () => picker(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));

describe("AttachReceiptControl", () => {
  it("shows the chat-image picker of this conversation with its own label", async () => {
    const { node, root } = await render();

    expect(picker(node).textContent).toBe(A.label);
    expect(picker(node).dataset.conversation).toBe("conv-1");
    await act(async () => root.unmount());
  });

  it("attaching the chosen image calls adjuntarComprobante with only the image and tells the panel", async () => {
    adjuntarComprobante.mockResolvedValue({ ok: true, compId: "COMP-1", reference: "104", amount: 13000, prefilled: true });
    const { node, root, onAttached } = await render();

    await pickImage(node);

    expect(adjuntarComprobante).toHaveBeenCalledWith("op-1", "wamid.ELEGIDA");
    expect(onAttached).toHaveBeenCalledTimes(1);
    expect(node.textContent).toContain(A.attachedPrefilled);
    await act(async () => root.unmount());
  });

  it("when nothing could be read from the image it says to type the reference and the amount", async () => {
    adjuntarComprobante.mockResolvedValue({ ok: true, compId: "COMP-1", reference: null, amount: null, prefilled: false });
    const { node, root } = await render();

    await pickImage(node);

    expect(node.textContent).toContain(A.attached);
    expect(node.textContent).not.toContain(A.attachedPrefilled);
    await act(async () => root.unmount());
  });

  it("a refusal shows the server's message and does not tell the panel", async () => {
    adjuntarComprobante.mockResolvedValue({ ok: false, status: 400, error: "this image is already a receipt of the operation" });
    const { node, root, onAttached } = await render();

    await pickImage(node);

    expect(node.textContent).toContain("this image is already a receipt of the operation");
    expect(onAttached).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
