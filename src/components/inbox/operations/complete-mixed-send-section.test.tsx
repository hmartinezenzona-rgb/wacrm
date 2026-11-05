// @vitest-environment jsdom
// "Completar envio": the inline section completes every part of a mixed send through the existing per-operation pipeline, one
// part after another. Side effects (deliver route command, image send, upload, Supabase) are mocked; the pipeline
// (`deliverDeal`) and the per-part container run for real.

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
vi.mock("@/lib/pipelines/send-proof-image", () => ({ sendProofImage: (...args: unknown[]) => sendProofImage(...args) }));
const uploadAccountMedia = vi.fn();
vi.mock("@/lib/storage/upload-media", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/storage/upload-media")>()),
  uploadAccountMedia: (...args: unknown[]) => uploadAccountMedia(...args),
  deleteAccountMedia: vi.fn(),
}));
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => {
    const builder = {
      select: () => builder,
      eq: () => builder,
      order: () => builder,
      limit: () => builder,
      maybeSingle: () => Promise.resolve({ data: { created_at: new Date().toISOString() }, error: null }),
    };
    return { from: () => builder };
  },
}));
vi.mock("@/hooks/use-can", () => ({ useCan: () => true }));
vi.mock("./cup-plan-block", () => ({ CupPlanBlock: () => null }));

const S = en.Inbox.operationsPanel.completeMixedSend;
const T = en.Inbox.operationsPanel.completeTransfer;

const PARTS = [
  { id: "op-zelle", title: "Zelle · 100 USD", method: "zelle", isZelle: true, beneficiaries: [{ id: "b1", isZelle: true }] },
  { id: "op-cup", title: "CUP card · 15,000 CUP", method: "cuban_card", isZelle: false, beneficiaries: [{ id: "b2", isZelle: false }] },
];

function pngFile(): File {
  const data = new Uint8Array(64);
  data.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  return { type: "image/png", size: 64, name: "capture.png", arrayBuffer: async () => data.buffer.slice(0) as ArrayBuffer } as unknown as File;
}

async function settle() {
  await act(async () => {
    for (let i = 0; i < 12; i += 1) await Promise.resolve();
  });
}

async function openSection(onClose = vi.fn()) {
  const { CompleteMixedSendSection } = await import("./complete-mixed-send-section");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(<CompleteMixedSendSection conversationId="conv-1" parts={PARTS} onClose={onClose} />),
  );
  return { root, onClose };
}

/** Icon-only buttons carry their name in aria-label. */
const button = (label: string) =>
  Array.from(document.body.querySelectorAll("button")).find((b) => (b.getAttribute("aria-label") ?? b.textContent?.trim()) === label) as
    | HTMLButtonElement
    | undefined;

const skipBox = () => document.body.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
async function tickSkip() {
  await act(async () => skipBox().click());
}

async function attach(index: number) {
  const input = document.body.querySelectorAll<HTMLInputElement>('input[type="file"]')[index]!;
  Object.defineProperty(input, "files", { value: [pngFile()], configurable: true });
  await act(async () => {
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await settle();
}

const confirmLabel = S.confirm.replace("{count}", "2");
const confirmSkipLabel = S.confirmSkip.replace("{count}", "2");

beforeEach(() => {
  vi.clearAllMocks();
  resetDeliveryLocks();
  URL.createObjectURL = vi.fn(() => "blob:preview");
  URL.revokeObjectURL = vi.fn();
  uploadAccountMedia.mockResolvedValue({ publicUrl: "https://storage.example/x.png", path: "acct/x.png" });
  sendProofImage.mockResolvedValue({ ok: true, wamid: "wamid.X" });
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ operations: PARTS.map((p) => ({ id: p.id, status: "ready_to_transfer" })) }),
    } as Response),
  );
});
afterEach(() => {
  document.body.replaceChildren();
  vi.unstubAllGlobals();
});

describe("CompleteMixedSendSection", () => {
  it("shows one block per part and keeps the confirm button disabled until every proof is attached", async () => {
    const { root } = await openSection();

    expect(document.body.textContent).toContain(PARTS[0]!.title);
    expect(document.body.textContent).toContain(PARTS[1]!.title);
    expect(button(confirmLabel)!.disabled).toBe(true);
    expect(document.body.textContent).toContain(S.missing.replace("{count}", "2"));

    await attach(0);
    expect(button(confirmLabel)!.disabled).toBe(true);
    await attach(1);
    expect(button(confirmLabel)!.disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("completes every part through the deliver route, once each and in order, then closes", async () => {
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root, onClose } = await openSection();
    await attach(0);
    await attach(1);

    await act(async () => button(confirmLabel)!.click());
    await settle();

    expect(deliverOperation.mock.calls.map((call) => call[0])).toEqual(["op-zelle", "op-cup"]);
    expect(deliverOperation.mock.calls[0]![1]).toMatchObject({ mode: "proof_sent" });
    expect(onClose).toHaveBeenCalledWith(true);
    await act(async () => root.unmount());
  });

  it("shows the refusal reason of a failing part and, on the next try, completes only the parts not done", async () => {
    deliverOperation
      .mockResolvedValueOnce({ ok: true, newStatus: "completed", completedAt: "x" })
      .mockResolvedValueOnce({
        ok: false,
        status: 400,
        error: "operation x has 0 GYD of verified funding but needs 6200 GYD",
      })
      .mockResolvedValueOnce({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root, onClose } = await openSection();
    await attach(0);
    await attach(1);

    await act(async () => button(confirmLabel)!.click());
    await settle();

    expect(deliverOperation.mock.calls.map((call) => call[0])).toEqual(["op-zelle", "op-cup"]);
    expect(document.body.textContent).toContain(T.refusal.fundingMissing.replace("{deposited}", "0").replace("{required}", "6,200"));
    expect(document.body.textContent).toContain(S.partDone);
    expect(onClose).not.toHaveBeenCalled();

    await act(async () => button(S.confirmRest.replace("{count}", "1"))!.click());
    await settle();

    expect(deliverOperation.mock.calls.map((call) => call[0])).toEqual(["op-zelle", "op-cup", "op-cup"]);
    expect(onClose).toHaveBeenCalledWith(true);
    await act(async () => root.unmount());
  });

  it("completes without screenshots from the one shared checkbox, sending no image", async () => {
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root, onClose } = await openSection();

    await tickSkip();
    await act(async () => button(confirmSkipLabel)!.click());
    await settle();

    expect(sendProofImage).not.toHaveBeenCalled();
    expect(deliverOperation.mock.calls.map((call) => call[0])).toEqual(["op-zelle", "op-cup"]);
    expect(onClose).toHaveBeenCalledWith(true);
    await act(async () => root.unmount());
  });

  it("passes the notify choice to every part", async () => {
    deliverOperation.mockResolvedValue({ ok: true, newStatus: "completed", completedAt: "x" });
    const { root } = await openSection();
    await act(async () => document.body.querySelector<HTMLButtonElement>("button[aria-pressed]")!.click());

    await tickSkip();
    await act(async () => button(confirmSkipLabel)!.click());
    await settle();

    expect(deliverOperation.mock.calls.map((call) => call[2])).toEqual([false, false]);
    await act(async () => root.unmount());
  });

  it("styles the section like the single-transfer one, with one title, one checkbox and one confirm row", async () => {
    const { root } = await openSection();

    const section = document.body.firstElementChild!.firstElementChild!;
    expect(section.className).toContain("bg-muted/30");
    expect(document.body.textContent).toContain(S.title);
    expect(document.body.querySelectorAll('input[type="checkbox"]')).toHaveLength(1);
    expect(document.body.textContent).toContain(T.withoutScreenshot);
    expect(document.body.querySelectorAll("button[aria-pressed]")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("previews the general customer message, with the brand in bold, only while the bell is on", async () => {
    const { root } = await openSection();

    const preview = () => Array.from(document.body.querySelectorAll("div")).find((d) => d.textContent?.includes(S.customerMessageTitle));
    expect(preview()).toBeTruthy();
    expect(preview()!.textContent).toContain("Listo, su envío ya fue completado. Gracias por confiar en Remesas Ya.");
    expect(preview()!.querySelector("strong")!.textContent).toBe("Remesas Ya");

    await act(async () => document.body.querySelector<HTMLButtonElement>("button[aria-pressed]")!.click());
    expect(preview()).toBeUndefined();
    await act(async () => root.unmount());
  });

  it("keeps the check disabled until the shared checkbox is ticked or every proof is attached", async () => {
    const { root } = await openSection();
    expect(button(confirmLabel)!.disabled).toBe(true);

    await tickSkip();
    expect(button(confirmSkipLabel)!.disabled).toBe(false);
    expect(document.body.textContent).not.toContain(S.missing.replace("{count}", "2"));
    await act(async () => root.unmount());
  });

  it("closes from the X with whether a part was completed", async () => {
    const { root, onClose } = await openSection();

    await act(async () => button(en.Inbox.operationsPanel.cancel)!.click());

    expect(onClose).toHaveBeenCalledWith(false);
    await act(async () => root.unmount());
  });
});
