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
const registerBeneficiaryProof = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  deliverOperation: (...args: unknown[]) => deliverOperation(...args),
  registerBeneficiaryProof: (...args: unknown[]) => registerBeneficiaryProof(...args),
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
  beneficiaries?: { id: string; isZelle: boolean }[];
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
        beneficiaries={options.beneficiaries ?? []}
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
    (b) => (b.textContent?.trim() || b.getAttribute("aria-label")) === T.complete || (b.textContent?.trim() || b.getAttribute("aria-label")) === T.sendAndComplete,
  ) as HTMLButtonElement;
}

function actionButton(node: Element, label: string): HTMLButtonElement | undefined {
  return Array.from(node.querySelectorAll("button")).find((b) => (b.textContent?.trim() || b.getAttribute("aria-label")) === label) as
    | HTMLButtonElement
    | undefined;
}

function pasteEventWithImage(file: File): Event {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { files: [file], items: [{ kind: "file", type: file.type }] },
  });
  return event;
}

function pasteEventWithText(text: string): Event {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { files: [], items: [{ kind: "string", type: "text/plain" }], getData: () => text },
  });
  return event;
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

/** Same as `pickFile`, targeting the `index`-th file input — used by the
 *  2+-beneficiary panel, which renders one drop zone per beneficiary. */
async function pickFileAt(node: Element, index: number, file: File) {
  const input = node.querySelectorAll<HTMLInputElement>('input[type="file"]')[index]!;
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

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "no_proof" }, true);
    expect(sendProofImage).not.toHaveBeenCalled();
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("the notify bell starts on, and turning it off sends notify=false to deliverOperation", async () => {
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const { node, root } = await renderContainer();

    const bell = node.querySelector<HTMLButtonElement>("button[aria-pressed]")!;
    expect(bell.getAttribute("aria-pressed")).toBe("true");
    expect(bell.getAttribute("aria-label")).toBe(en.Inbox.operationsPanel.notify.on);

    await act(async () => bell.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    expect(bell.getAttribute("aria-pressed")).toBe("false");

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "no_proof" }, false);
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
    }, true);
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

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "skip_proof" }, true);
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
    }, true);
    await act(async () => root.unmount());
  });

  it("a funding refusal shows the reason in plain words and no Retry", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage.mockResolvedValue({ ok: true, wamid: "wamid.ABC" });
    deliverOperation.mockResolvedValueOnce({
      ok: false,
      status: 400,
      error: "the operation has 0 GYD of verified funding but needs 6200 GYD: verify the deposit before delivering",
    });
    const { node, root } = await renderContainer();

    await pickFile(node, pngFile());
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain("Deposit not verified yet: it has 0 of 6,200 GYD");
    expect(node.textContent).not.toContain(T.stageFailed);
    expect(actionButton(node, T.retry)).toBeUndefined();
    await act(async () => root.unmount());
  });

  it("an unknown refusal shows the server text without Retry; a 5xx keeps Retry", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage.mockResolvedValue({ ok: true, wamid: "wamid.ABC" });
    deliverOperation.mockResolvedValueOnce({ ok: false, status: 400, error: "some new server rule" });
    const { node, root } = await renderContainer();

    await pickFile(node, pngFile());
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();
    expect(node.textContent).toContain("some new server rule");
    expect(actionButton(node, T.retry)).toBeUndefined();

    deliverOperation.mockResolvedValueOnce({ ok: false, status: 500, error: "Request failed" });
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();
    expect(node.textContent).toContain(T.stageFailed);
    expect(actionButton(node, T.retry)).toBeDefined();
    await act(async () => root.unmount());
  });

  it("document paste of an image file attaches it without clicking the picker", async () => {
    const { node, root } = await renderContainer();

    await act(async () => {
      document.dispatchEvent(pasteEventWithImage(pngFile()));
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(node.querySelector("img")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("paste into the caption textarea with plain text does not attach or replace the file", async () => {
    const { node, root } = await renderContainer({ isZelle: true });
    await pickFile(node, pngFile());
    expect(URL.createObjectURL).toHaveBeenCalledTimes(1);

    const textarea = node.querySelector("textarea")!;
    await act(async () => {
      textarea.dispatchEvent(pasteEventWithText("hello"));
      await Promise.resolve();
    });

    expect(URL.createObjectURL).toHaveBeenCalledTimes(1);
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

// ---------------------------------------------------------------
// Per-beneficiary delivery proof (P3): 2+ current beneficiaries.
// ---------------------------------------------------------------

const BENEFICIARIES_2 = [
  { id: "ben-1", isZelle: true },
  { id: "ben-2", isZelle: false },
];

describe("CompleteTransferContainer — 2+ beneficiaries", () => {
  it("renders one proof panel per beneficiary, caption only for the Zelle one", async () => {
    const { node, root } = await renderContainer({ beneficiaries: BENEFICIARIES_2 });

    expect(node.querySelectorAll('input[type="file"]').length).toBe(2);
    await pickFileAt(node, 0, pngFile());
    await pickFileAt(node, 1, pngFile());

    expect(node.querySelectorAll("textarea").length).toBe(1);
    await act(async () => root.unmount());
  });

  it("sends each image, registers it, then delivers once — in order", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage
      .mockResolvedValueOnce({ ok: true, wamid: "wamid.BEN1" })
      .mockResolvedValueOnce({ ok: true, wamid: "wamid.BEN2" });
    registerBeneficiaryProof.mockResolvedValue({ ok: true, registered: true, missing: 0 });
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const onDone = vi.fn();

    const { node, root } = await renderContainer({ beneficiaries: BENEFICIARIES_2, onDone });
    await pickFileAt(node, 0, pngFile());
    await pickFileAt(node, 1, pngFile());

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(sendProofImage).toHaveBeenCalledTimes(2);
    expect(registerBeneficiaryProof).toHaveBeenCalledTimes(2);
    expect(registerBeneficiaryProof).toHaveBeenNthCalledWith(
      1,
      OPERATION_ID,
      "ben-1",
      expect.objectContaining({ wamid: "wamid.BEN1" }),
    );
    expect(registerBeneficiaryProof).toHaveBeenNthCalledWith(
      2,
      OPERATION_ID,
      "ben-2",
      expect.objectContaining({ wamid: "wamid.BEN2" }),
    );
    expect(deliverOperation).toHaveBeenCalledTimes(1);
    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, {
      mode: "proof_sent",
      wamid: "wamid.BEN2",
      path: "account-1/x.png",
    }, true);
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("a failure on the second image stops, keeps the first sent, and a retry sends only the second", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage
      .mockResolvedValueOnce({ ok: true, wamid: "wamid.BEN1" })
      .mockResolvedValueOnce({ ok: false, outcome: "not-sent", message: "Meta 131047" });
    registerBeneficiaryProof.mockResolvedValue({ ok: true, registered: true, missing: 0 });

    const { node, root } = await renderContainer({ beneficiaries: BENEFICIARIES_2 });
    await pickFileAt(node, 0, pngFile());
    await pickFileAt(node, 1, pngFile());

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain("Meta 131047");
    expect(sendProofImage).toHaveBeenCalledTimes(2);
    expect(registerBeneficiaryProof).toHaveBeenCalledTimes(1);
    expect(deliverOperation).not.toHaveBeenCalled();

    // Retry: beneficiary 1 must not be re-sent, only beneficiary 2.
    sendProofImage.mockResolvedValueOnce({ ok: true, wamid: "wamid.BEN2" });
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const retry = actionButton(node, T.retry)!;
    await act(async () => retry.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(sendProofImage).toHaveBeenCalledTimes(3);
    expect(registerBeneficiaryProof).toHaveBeenCalledTimes(3);
    expect(deliverOperation).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("skip checkbox bypasses every beneficiary's proof: no sends, no registrations, one skip_proof delivery", async () => {
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });
    const { node, root } = await renderContainer({ beneficiaries: BENEFICIARIES_2 });

    const checkbox = node.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
    await act(async () => {
      checkbox.click();
    });

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(sendProofImage).not.toHaveBeenCalled();
    expect(registerBeneficiaryProof).not.toHaveBeenCalled();
    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "skip_proof" }, true);
    await act(async () => root.unmount());
  });

  it("1 beneficiary still uses the single-proof path (no registration call)", async () => {
    uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "account-1/x.png" });
    sendProofImage.mockResolvedValue({ ok: true, wamid: "wamid.ABC" });
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "2026-09-15T00:00:00Z" });

    const { node, root } = await renderContainer({ beneficiaries: [{ id: "ben-1", isZelle: true }] });
    await pickFile(node, pngFile());

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(registerBeneficiaryProof).not.toHaveBeenCalled();
    expect(sendProofImage).toHaveBeenCalledTimes(1);
    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, {
      mode: "proof_sent",
      wamid: "wamid.ABC",
      path: "account-1/x.png",
    }, true);
    await act(async () => root.unmount());
  });
});

describe("CompleteTransferContainer: CUP source card (migration 257)", () => {
  async function cupPlan() {
    const { mapCupPanel } = await import("@/lib/cup-inventory/panel");
    return mapCupPanel({
      state: "plan", total_cup: 50000, planned_cup: 50000, missing_cup: 0, cuba_day: "2026-10-20", effective_rate: 960, source_card_id: null,
      cards: [
        { id: "card-a", name: "Tarjeta A", last4: "1111", balance_cup: 380000, remaining_limit_today_cup: 20000 },
        { id: "card-b", name: "Tarjeta B", last4: "2222", balance_cup: 250000, remaining_limit_today_cup: 120000 },
      ],
      beneficiaries: [{ beneficiary_id: "b1", position: 1, name: "Ana", amount_cup: 50000, missing_cup: 0,
        lines: [{ card_id: "card-a", card_name: "Tarjeta A", last4: "1111", lot_id: "l1", amount_cup: 50000, lot_rate: 960 }] }],
    });
  }

  async function stubFetch() {
    const plan = await cupPlan();
    const fetchMock = vi.fn((url: string) =>
      url.includes("/cup-plan")
        ? Promise.resolve(new Response(JSON.stringify({ cupPlan: plan }), { status: 200 }))
        : Promise.resolve(readyOperationsResponse()),
    );
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  function pick(node: Element, value: string) {
    const el = node.querySelector("select") as HTMLSelectElement;
    return act(async () => {
      el.value = value;
      el.dispatchEvent(new Event("change", { bubbles: true }));
      await Promise.resolve();
    });
  }

  it("defaults to automatic: completing sends no source card (the old call)", async () => {
    await stubFetch();
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root } = await renderContainer();
    await flush();
    expect((node.querySelector("select") as HTMLSelectElement).value).toBe("");

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "no_proof" }, true);
    await act(async () => root.unmount());
  });

  it("choosing a card re-reads the plan from that card and completing sends the choice", async () => {
    const fetchMock = await stubFetch();
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root } = await renderContainer();
    await flush();

    await pick(node, "card-b");
    await flush();
    expect(fetchMock).toHaveBeenCalledWith(`/api/remittance-operations/${OPERATION_ID}/cup-plan?card=card-b`, expect.anything());

    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "no_proof" }, true, "card-b");
    await act(async () => root.unmount());
  });

  it("going back to automatic completes without a source card again", async () => {
    await stubFetch();
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: null });
    const { node, root } = await renderContainer();
    await flush();

    await pick(node, "card-b");
    await flush();
    await pick(node, "");
    await flush();
    await act(async () => submitButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(deliverOperation).toHaveBeenCalledWith(OPERATION_ID, { mode: "no_proof" }, true);
    await act(async () => root.unmount());
  });
});

describe("CompleteTransferContainer: Clásica / Tropical balance block", () => {
  const blockedPlan = {
    state: "plan", estimate: true, cubaMonth: "2026-11-01", blocked: true,
    services: [{ service: "TROPICAL", neededUsd: 400, plannedUsd: 250, missingUsd: 150, blocked: true, investedUsdt: 238, lines: [] }],
  };
  const okPlan = { ...blockedPlan, blocked: false, services: [{ ...blockedPlan.services[0], blocked: false, missingUsd: 0 }] };

  function stubUsd(plan: unknown) {
    vi.stubGlobal(
      "fetch",
      vi.fn((url: string) =>
        url.includes("/usd-plan")
          ? Promise.resolve(new Response(JSON.stringify({ usdPlan: plan }), { status: 200 }))
          : Promise.resolve(readyOperationsResponse()),
      ),
    );
  }

  it("a short balance shows the red message and disables completing", async () => {
    stubUsd(blockedPlan);
    const { node, root } = await renderContainer();
    await flush();

    expect(node.textContent).toContain("150 USD missing on Tropical: buy balance before completing");
    expect(submitButton(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("with enough balance the complete button stays enabled", async () => {
    stubUsd(okPlan);
    const { node, root } = await renderContainer();
    await flush();

    expect(node.textContent).not.toContain("150 USD missing");
    expect(submitButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });
});
