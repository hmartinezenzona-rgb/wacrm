// @vitest-environment jsdom
// Spec: panel-23 "Complete transfer" section. Container wires the real
// `deliverDeal` pipeline (deliver-with-proof.ts) to the operations panel's
// delivery endpoint. Every actual side effect is mocked: the command
// (`deliverOperation`), the image send (`sendProofImage`), the storage
// upload helpers, the browser Supabase client (used only for the 24-hour
// window check) and `useCan`. `deliverDeal` itself runs for real, so these
// tests exercise the real order-of-operations end to end.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { resetDeliveryLocks } from "@/lib/pipelines/deliver-with-proof";

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

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

const deliverOperation = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  deliverOperation: (...args: unknown[]) => deliverOperation(...args),
}));

const sendProofImage = vi.fn();
vi.mock("@/lib/pipelines/send-proof-image", () => ({
  sendProofImage: (...args: unknown[]) => sendProofImage(...args),
}));

const uploadAccountMedia = vi.fn();
const deleteAccountMedia = vi.fn();
vi.mock("@/lib/storage/upload-media", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/storage/upload-media")>();
  return {
    ...actual,
    uploadAccountMedia: (...args: unknown[]) => uploadAccountMedia(...args),
    deleteAccountMedia: (...args: unknown[]) => deleteAccountMedia(...args),
  };
});

const messagesResult = { value: { data: null as { created_at: string } | null, error: null as unknown } };
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => {
      if (table !== "messages") throw new Error(`unexpected table ${table}`);
      const builder = {
        select: () => builder,
        eq: () => builder,
        order: () => builder,
        limit: () => builder,
        maybeSingle: () => Promise.resolve(messagesResult.value),
      };
      return builder;
    },
  }),
}));

const useCan = vi.fn(() => true);
vi.mock("@/hooks/use-can", () => ({ useCan: () => useCan() }));

const T = en.Inbox.operationsPanel.completeTransfer;
const OPERATION_ID = "op-1";
const CONVERSATION_ID = "conv-1";

function windowOpen() {
  messagesResult.value = { data: { created_at: new Date().toISOString() }, error: null };
}

function windowClosed() {
  messagesResult.value = { data: null, error: null };
}

function readyOperationsResponse(status = "ready_to_transfer") {
  return {
    ok: true,
    json: () =>
      Promise.resolve({
        resolverState: "unica",
        resolverOperationId: OPERATION_ID,
        resolverCandidateCount: 1,
        operations: [{ id: OPERATION_ID, status }],
      }),
  } as Response;
}

const PNG_HEADER = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

// A plain object cast as `File`, not a real DOM `File` — jsdom's `File`
// does not implement `arrayBuffer()` (see `deliver-with-proof.test.ts`'s
// own `pngFile()`, which uses the same workaround).
function pngFile(): File {
  const data = new Uint8Array(64);
  data.set(PNG_HEADER, 0);
  return {
    type: "image/png",
    size: data.byteLength,
    name: "capture.png",
    arrayBuffer: async () => data.buffer.slice(0) as ArrayBuffer,
  } as unknown as File;
}

interface RenderOptions {
  isZelle?: boolean;
  onDone?: () => void;
  onCancel?: () => void;
}

async function renderContainer(options: RenderOptions = {}) {
  const { CompleteTransferContainer } = await import("./complete-transfer-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onDone = options.onDone ?? vi.fn();
  const onCancel = options.onCancel ?? vi.fn();
  await act(async () =>
    root.render(
      <CompleteTransferContainer
        operationId={OPERATION_ID}
        conversationId={CONVERSATION_ID}
        isZelle={options.isZelle ?? false}
        onDone={onDone}
        onCancel={onCancel}
      />,
    ),
  );
  return { node, root, onDone, onCancel };
}

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  });
}

function submitButton(node: Element): HTMLButtonElement {
  return Array.from(node.querySelectorAll("button")).find(
    (b) => b.textContent?.trim() === T.complete || b.textContent?.trim() === T.sendAndComplete,
  ) as HTMLButtonElement;
}

function actionButton(node: Element, label: string): HTMLButtonElement | undefined {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === label) as
    | HTMLButtonElement
    | undefined;
}

async function pickFile(node: Element, file: File) {
  const input = node.querySelector<HTMLInputElement>('input[type="file"]')!;
  Object.defineProperty(input, "files", { value: [file], configurable: true });
  await act(async () => {
    input.dispatchEvent(new Event("change", { bubbles: true }));
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  useCan.mockReturnValue(true);
  windowOpen();
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(readyOperationsResponse()));
  URL.createObjectURL = vi.fn(() => "blob:test-preview");
  URL.revokeObjectURL = vi.fn();
  resetDeliveryLocks();
});

afterEach(() => {
  document.body.replaceChildren();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("CompleteTransferContainer", () => {
  it("shows the note field when isZelle is true", async () => {
    const { node, root } = await renderContainer({ isZelle: true });
    await pickFile(node, pngFile());

    expect(node.querySelector("textarea")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("hides the note field when isZelle is false", async () => {
    const { node, root } = await renderContainer({ isZelle: false });
    await pickFile(node, pngFile());

    expect(node.querySelector("textarea")).toBeNull();
    await act(async () => root.unmount());
  });

  it("no file + Complete calls deliverOperation with mode:'no_proof' and calls onDone", async () => {
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const onDone = vi.fn();
    const { node, root } = await renderContainer({ onDone });

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "no_proof" });
    expect(sendProofImage).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("with an accepted file: uploads, sends with the caption, then delivers proof_sent with wamid/path", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage.mockResolvedValue({ ok: true, wamid: "wamid.ABC" });
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const onDone = vi.fn();
    const { node, root } = await renderContainer({ isZelle: true, onDone });

    await pickFile(node, pngFile());

    const textarea = node.querySelector<HTMLTextAreaElement>("textarea")!;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!;
    await act(async () => {
      setter.call(textarea, "Nombre del remitente: Juan");
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    });

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(uploadAccountMedia).toHaveBeenCalledTimes(1);
    expect(sendProofImage).toHaveBeenCalledWith(
      expect.objectContaining({ caption: "Nombre del remitente: Juan" }),
    );
    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, {
      mode: "proof_sent",
      wamid: "wamid.ABC",
      path: "account-1/x.png",
    });
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("window closed: shows the message, and 'Complete anyway' delivers skip_proof without sending", async () => {
    windowClosed();
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const { node, root } = await renderContainer();

    await pickFile(node, pngFile());
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain(T.windowClosed);
    expect(sendProofImage).not.toHaveBeenCalled();

    const completeAnyway = actionButton(node, T.completeAnyway)!;
    await act(async () => completeAnyway.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "skip_proof" });
    expect(sendProofImage).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("send failure: shows the failed message and does not call deliverOperation", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage.mockResolvedValue({ ok: false, outcome: "not-sent", message: "Meta 131047" });
    const { node, root } = await renderContainer();

    await pickFile(node, pngFile());
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain("Meta 131047");
    expect(deliverOperation).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("stage failure after a successful send: Retry does not re-send, only re-delivers", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage.mockResolvedValue({ ok: true, wamid: "wamid.ABC" });
    deliverOperation.mockResolvedValueOnce({ ok: false, status: 409, error: "stale" });
    const { node, root } = await renderContainer();

    await pickFile(node, pngFile());
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain(T.stageFailed);
    expect(sendProofImage).toHaveBeenCalledTimes(1);

    deliverOperation.mockResolvedValueOnce({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const retry = actionButton(node, T.retry)!;
    await act(async () => retry.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(sendProofImage).toHaveBeenCalledTimes(1);
    expect(deliverOperation).toHaveBeenCalledTimes(2);
    // A stage-only retry (draft.sentWamid already set) never re-derives
    // `path` — deliver-with-proof.ts's retry branch carries `wamid` alone.
    expect(deliverOperation).toHaveBeenLastCalledWith(OPERATION_ID, {
      mode: "proof_sent",
      wamid: "wamid.ABC",
    });
    await act(async () => root.unmount());
  });

  it("Cancel calls onCancel and revokes the preview object URL", async () => {
    const onCancel = vi.fn();
    const { node, root } = await renderContainer({ onCancel });

    await pickFile(node, pngFile());

    const cancelButton = actionButton(node, en.Inbox.operationsPanel.cancel)!;
    await act(async () => cancelButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:test-preview");
    await act(async () => root.unmount());
  });
});
