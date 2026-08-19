import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  deliverDeal,
  isDeliveryInFlight,
  resetDeliveryLocks,
  type DeliveryDeps,
  type SendProofOutcome,
} from "./deliver-with-proof";
import type { DeliveryProofDraft } from "./delivery-proof";
import { DELIVERY_PROOF_STAGE_ID } from "./delivery-stages";

const PNG_HEADER = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** A `File`-shaped object carrying a real PNG header. */
function pngFile(): File {
  const data = new Uint8Array(64);
  data.set(PNG_HEADER, 0);
  return {
    type: "image/png",
    size: data.byteLength,
    name: "Captura de pantalla 2026-08-18.png",
    arrayBuffer: async () => data.buffer.slice(0) as ArrayBuffer,
  } as unknown as File;
}

function draftFor(
  dealId: string,
  over: Partial<DeliveryProofDraft> = {},
): DeliveryProofDraft {
  return {
    dealId,
    file: pngFile(),
    kind: "png",
    previewUrl: `blob:${dealId}`,
    caption: "",
    ...over,
  };
}

/**
 * Every dependency spied, all succeeding. Each test overrides only
 * the one it is about, so the assertions that matter most —
 * "and nothing else was called" — stay readable.
 */
function deps(over: Partial<DeliveryDeps> = {}) {
  return {
    canSend: vi.fn(() => true),
    isWindowOpen: vi.fn(async () => true),
    readStage: vi.fn(async () => DELIVERY_PROOF_STAGE_ID),
    uploadProof: vi.fn(async () => ({
      publicUrl: "https://storage.example/account-1/1234-prueba-entrega.png",
      path: "account-1/1234-prueba-entrega.png",
    })),
    sendProof: vi.fn(
      async (): Promise<SendProofOutcome> => ({ ok: true, wamid: "wamid.ABC" }),
    ),
    discardUpload: vi.fn(async () => {}),
    moveToDelivered: vi.fn(async () => ({ ok: true as const })),
    ...over,
  } satisfies DeliveryDeps;
}

/** Nothing left the browser. */
function expectNoSideEffects(d: ReturnType<typeof deps>) {
  expect(d.uploadProof).not.toHaveBeenCalled();
  expect(d.sendProof).not.toHaveBeenCalled();
  expect(d.moveToDelivered).not.toHaveBeenCalled();
}

beforeEach(() => {
  resetDeliveryLocks();
});

// ---------------------------------------------------------------
// DP-09 — the invariant that matters most
// ---------------------------------------------------------------

describe("a deal without a proof", () => {
  it("does exactly what it did before: one stage update, nothing else", async () => {
    const d = deps();
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: null },
      d,
    );

    expect(result).toEqual({ status: "delivered", proofSent: false });
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
    expect(d.moveToDelivered).toHaveBeenCalledWith("deal-1");
    expect(d.uploadProof).not.toHaveBeenCalled();
    expect(d.sendProof).not.toHaveBeenCalled();
    // Not even the cheap probes run — a deal with no proof must not
    // be able to tell this feature was deployed.
    expect(d.canSend).not.toHaveBeenCalled();
    expect(d.isWindowOpen).not.toHaveBeenCalled();
  });

  it("still moves without a conversation, as it always has", async () => {
    const d = deps();
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: null, draft: null },
      d,
    );
    expect(result).toEqual({ status: "delivered", proofSent: false });
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
  });

  it("reports a failed stage update without claiming a proof was sent", async () => {
    const d = deps({
      moveToDelivered: vi.fn(async () => ({ ok: false as const, message: "RLS" })),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: null },
      d,
    );
    expect(result).toEqual({
      status: "stage-failed",
      message: "RLS",
      proofSent: false,
    });
  });
});

// ---------------------------------------------------------------
// DP-10 — the happy path
// ---------------------------------------------------------------

describe("a deal with a proof and an open window", () => {
  it("uploads, sends, then moves the stage — in that order", async () => {
    const order: string[] = [];
    const d = deps({
      uploadProof: vi.fn(async () => {
        order.push("upload");
        return { publicUrl: "https://storage/x.png", path: "account-1/x.png" };
      }),
      sendProof: vi.fn(async () => {
        order.push("send");
        return { ok: true as const, wamid: "wamid.ABC" };
      }),
      moveToDelivered: vi.fn(async () => {
        order.push("move");
        return { ok: true as const };
      }),
    });

    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1", { caption: "Nombre del remitente: Juan Pérez" }),
      },
      d,
    );

    expect(result).toEqual({
      status: "delivered",
      proofSent: true,
      wamid: "wamid.ABC",
    });
    expect(order).toEqual(["upload", "send", "move"]);
  });

  it("uploads under the generic name, not the customer's screenshot name", async () => {
    const d = deps();
    await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(d.uploadProof).toHaveBeenCalledWith(
      expect.anything(),
      "prueba-entrega.png",
    );
  });

  it("sends the note as the image caption, trimmed", async () => {
    const d = deps();
    await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1", { caption: "  Nombre del remitente: Juan  " }),
      },
      d,
    );
    expect(d.sendProof).toHaveBeenCalledWith({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/account-1/1234-prueba-entrega.png",
      caption: "Nombre del remitente: Juan",
    });
  });

  it("sends an empty caption when no note was written", async () => {
    const d = deps();
    await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(d.sendProof).toHaveBeenCalledWith(
      expect.objectContaining({ caption: "" }),
    );
  });
});

// ---------------------------------------------------------------
// DP-11 / DP-12 — failures before the stage moves
// ---------------------------------------------------------------

describe("when the upload fails", () => {
  // DP-11
  it("does not send and does not move the deal", async () => {
    const d = deps({
      uploadProof: vi.fn(async () => {
        throw new Error("bucket unreachable");
      }),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toEqual({
      status: "failed",
      phase: "upload",
      message: "bucket unreachable",
    });
    expect(d.sendProof).not.toHaveBeenCalled();
    expect(d.moveToDelivered).not.toHaveBeenCalled();
    // Nothing was uploaded, so there is nothing to clean up.
    expect(d.discardUpload).not.toHaveBeenCalled();
  });
});

describe("when the send fails", () => {
  // DP-12
  it("takes the object back out of the public bucket and leaves the deal put", async () => {
    const d = deps({
      sendProof: vi.fn(
        async (): Promise<SendProofOutcome> => ({
          ok: false,
          outcome: "not-sent",
          message: "Meta 131047",
        }),
      ),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toEqual({
      status: "failed",
      phase: "send",
      message: "Meta 131047",
    });
    expect(d.discardUpload).toHaveBeenCalledWith("account-1/1234-prueba-entrega.png");
    expect(d.moveToDelivered).not.toHaveBeenCalled();
  });

  it("treats a thrown send as unconfirmed, not as a clean failure", async () => {
    const d = deps({
      sendProof: vi.fn(async () => {
        throw new Error("network error");
      }),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    // No response came back, so we cannot say the customer did not
    // get it. The object stays where it is and the deal stays put.
    expect(result).toMatchObject({ status: "unconfirmed" });
    expect(d.discardUpload).not.toHaveBeenCalled();
    expect(d.moveToDelivered).not.toHaveBeenCalled();
  });

  it("still reports the send error when the cleanup itself fails", async () => {
    const d = deps({
      sendProof: vi.fn(
        async (): Promise<SendProofOutcome> => ({
          ok: false,
          outcome: "not-sent",
          message: "Meta 400",
        }),
      ),
      discardUpload: vi.fn(async () => {
        throw new Error("delete failed");
      }),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    // The operator needs to read the send failure, not a storage nit.
    expect(result).toMatchObject({ status: "failed", phase: "send", message: "Meta 400" });
  });
});

// ---------------------------------------------------------------
// DP-13 — the only serious partial failure
// ---------------------------------------------------------------

describe("when the proof arrives but the stage update fails", () => {
  it("reports it as sent, carrying the wamid back", async () => {
    const d = deps({
      moveToDelivered: vi.fn(async () => ({
        ok: false as const,
        message: "network error",
      })),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toEqual({
      status: "stage-failed",
      message: "network error",
      proofSent: true,
      wamid: "wamid.ABC",
    });
    // The image is with the customer — it must NOT be pulled from the
    // bucket, or the message they received would break.
    expect(d.discardUpload).not.toHaveBeenCalled();
  });

  it("retries the stage only, never re-sending the image", async () => {
    const d = deps();
    const sent = draftFor("deal-1", { sentWamid: "wamid.ABC" });

    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: sent },
      d,
    );

    expect(result).toEqual({
      status: "delivered",
      proofSent: true,
      wamid: "wamid.ABC",
    });
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
    expect(d.uploadProof).not.toHaveBeenCalled();
    expect(d.sendProof).not.toHaveBeenCalled();
    // Not re-probed either: the send already happened.
    expect(d.isWindowOpen).not.toHaveBeenCalled();
  });

  it("keeps offering the retry when it fails again", async () => {
    const d = deps({
      moveToDelivered: vi.fn(async () => ({ ok: false as const, message: "still down" })),
    });
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1", { sentWamid: "wamid.ABC" }),
      },
      d,
    );
    expect(result).toEqual({
      status: "stage-failed",
      message: "still down",
      proofSent: true,
      wamid: "wamid.ABC",
    });
    expect(d.sendProof).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------
// DP-14 — the 24-hour window
// ---------------------------------------------------------------

describe("when the 24-hour window is closed", () => {
  it("refuses before uploading anything and asks the operator", async () => {
    const d = deps({ isWindowOpen: vi.fn(async () => false) });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toEqual({ status: "window-closed" });
    expectNoSideEffects(d);
  });

  it("delivers without the proof when the operator chooses to", async () => {
    const d = deps({ isWindowOpen: vi.fn(async () => false) });
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1"),
        skipProof: true,
      },
      d,
    );

    // The template still goes out through n8n — it crosses a closed
    // window; only the free-form image cannot.
    expect(result).toEqual({ status: "delivered", proofSent: false });
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
    expect(d.uploadProof).not.toHaveBeenCalled();
    expect(d.sendProof).not.toHaveBeenCalled();
  });

  it("re-checks at confirm time, not only when the panel was opened", async () => {
    const d = deps({ isWindowOpen: vi.fn(async () => false) });
    await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(d.isWindowOpen).toHaveBeenCalledWith("conv-1");
  });
});

// ---------------------------------------------------------------
// DP-15 — permissions
// ---------------------------------------------------------------

describe("without send permission", () => {
  it("refuses before uploading, sending or moving", async () => {
    const d = deps({ canSend: vi.fn(() => false) });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toEqual({ status: "blocked", reason: "permission" });
    expectNoSideEffects(d);
    // The permission gate comes first — a viewer must not even cause
    // a window query.
    expect(d.isWindowOpen).not.toHaveBeenCalled();
  });
});

describe("when the deal has no conversation", () => {
  it("refuses rather than sending into the void", async () => {
    const d = deps();
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: null, draft: draftFor("deal-1") },
      d,
    );
    expect(result).toEqual({ status: "blocked", reason: "no-conversation" });
    expectNoSideEffects(d);
  });
});

describe("when the file no longer validates", () => {
  it("refuses at confirm time", async () => {
    const bad = draftFor("deal-1");
    bad.file = {
      type: "image/png",
      size: 10,
      // GIF bytes behind a PNG label.
      arrayBuffer: async () =>
        new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]).buffer,
    } as unknown as File;

    const d = deps();
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: bad },
      d,
    );
    expect(result).toEqual({ status: "blocked", reason: "invalid-file" });
    expectNoSideEffects(d);
  });
});

// ---------------------------------------------------------------
// DP-16 / DP-17 — concurrency and cross-deal leakage
// ---------------------------------------------------------------

describe("two deliveries racing on the same deal", () => {
  it("produces one upload, one send and one stage update", async () => {
    // A real lock needs a real overlap: the upload parks on a promise
    // that only resolves once BOTH calls have been made, so the second
    // call is guaranteed to arrive while the first is still in flight.
    let releaseUpload!: () => void;
    const uploadStarted = new Promise<void>((resolve) => {
      releaseUpload = resolve;
    });

    const d = deps({
      uploadProof: vi.fn(async () => {
        await uploadStarted;
        return { publicUrl: "https://storage/x.png", path: "account-1/x.png" };
      }),
    });

    const req = {
      dealId: "deal-1",
      conversationId: "conv-1",
      draft: draftFor("deal-1"),
    };

    const first = deliverDeal(req, d);
    const second = deliverDeal(req, d);

    expect(isDeliveryInFlight("deal-1")).toBe(true);
    releaseUpload();

    const [a, b] = await Promise.all([first, second]);

    expect(a).toMatchObject({ status: "delivered", proofSent: true });
    expect(b).toEqual({ status: "busy" });
    expect(d.uploadProof).toHaveBeenCalledTimes(1);
    expect(d.sendProof).toHaveBeenCalledTimes(1);
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
  });

  it("releases the lock once finished, so a retry can run", async () => {
    const d = deps();
    const req = {
      dealId: "deal-1",
      conversationId: "conv-1",
      draft: draftFor("deal-1"),
    };
    await deliverDeal(req, d);
    expect(isDeliveryInFlight("deal-1")).toBe(false);
    await deliverDeal(req, d);
    expect(d.moveToDelivered).toHaveBeenCalledTimes(2);
  });

  it("releases the lock even when the run throws", async () => {
    const d = deps({
      moveToDelivered: vi.fn(async () => {
        throw new Error("boom");
      }),
    });
    await expect(
      deliverDeal({ dealId: "deal-1", conversationId: "conv-1", draft: null }, d),
    ).rejects.toThrow("boom");
    expect(isDeliveryInFlight("deal-1")).toBe(false);
  });

  it("does not make one deal wait for another", async () => {
    let release!: () => void;
    const parked = new Promise<void>((r) => {
      release = r;
    });
    const d = deps({
      uploadProof: vi.fn(async () => {
        await parked;
        return { publicUrl: "https://storage/x.png", path: "account-1/x.png" };
      }),
    });

    const slow = deliverDeal(
      { dealId: "deal-A", conversationId: "conv-A", draft: draftFor("deal-A") },
      d,
    );
    const other = await deliverDeal(
      { dealId: "deal-B", conversationId: "conv-B", draft: null },
      d,
    );

    expect(other).toEqual({ status: "delivered", proofSent: false });
    release();
    await slow;
  });
});

describe("a draft belonging to another deal", () => {
  // DP-17
  it("is refused rather than sent to the wrong customer", async () => {
    const d = deps();
    const result = await deliverDeal(
      {
        dealId: "deal-B",
        conversationId: "conv-B",
        draft: draftFor("deal-A"),
      },
      d,
    );

    expect(result).toEqual({ status: "blocked", reason: "draft-mismatch" });
    expectNoSideEffects(d);
  });
});

// ---------------------------------------------------------------
// SEND-01 — Meta accepted, WaCRM did not record it
//
// The gap this covers: `/api/whatsapp/send` sends to Meta FIRST and
// inserts the `messages` row after. If that insert fails, the
// customer already has the image and the endpoint still answers
// with an HTTP error. Reading that as "the send failed" and
// retrying would deliver the same screenshot twice.
// ---------------------------------------------------------------

describe("when Meta accepted but WaCRM could not record it", () => {
  const dbErrorSend = () =>
    vi.fn(
      async (): Promise<SendProofOutcome> => ({
        ok: false,
        outcome: "sent-not-recorded",
        message: "Message sent to Meta but failed to save to DB: timeout",
        wamid: "wamid.SENT",
      }),
    );

  // SEND-01D
  it("does not delete the object the customer is being served", async () => {
    const d = deps({ sendProof: dbErrorSend() });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toMatchObject({
      status: "sent-not-recorded",
      wamid: "wamid.SENT",
    });
    // Deleting it would break the message they already received.
    expect(d.discardUpload).not.toHaveBeenCalled();
  });

  it("does not move the stage on its own", async () => {
    const d = deps({ sendProof: dbErrorSend() });
    await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(d.moveToDelivered).not.toHaveBeenCalled();
  });

  it("recovers with a stage-only retry once the wamid is on the draft", async () => {
    const d = deps();
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1", { sentWamid: "wamid.SENT" }),
      },
      d,
    );

    expect(result).toMatchObject({ status: "delivered", proofSent: true });
    expect(d.sendProof).not.toHaveBeenCalled();
    expect(d.uploadProof).not.toHaveBeenCalled();
  });

  it("is not confused with a plain send failure", async () => {
    const notSent = deps({
      sendProof: vi.fn(
        async (): Promise<SendProofOutcome> => ({
          ok: false,
          outcome: "not-sent",
          message: "Meta 131047",
        }),
      ),
    });
    // SEND-01E — a genuine non-delivery cleans up and stays retryable.
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      notSent,
    );
    expect(result).toMatchObject({ status: "failed", phase: "send" });
    expect(notSent.discardUpload).toHaveBeenCalled();
    expect(notSent.moveToDelivered).not.toHaveBeenCalled();
  });
});

describe("when the send never came back", () => {
  it("keeps the object and refuses to guess", async () => {
    const d = deps({
      sendProof: vi.fn(
        async (): Promise<SendProofOutcome> => ({
          ok: false,
          outcome: "unconfirmed",
          message: "Failed to fetch",
        }),
      ),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toMatchObject({ status: "unconfirmed" });
    // It may well have been delivered — deleting the object could
    // break a message the customer already has.
    expect(d.discardUpload).not.toHaveBeenCalled();
    expect(d.moveToDelivered).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------
// CONC-01 — another session moved the deal first
// ---------------------------------------------------------------

describe("when the deal moved on in another session", () => {
  it("aborts before uploading or sending anything", async () => {
    const d = deps({
      // Already in Entregada — someone else delivered it.
      readStage: vi.fn(async () => "1b36b34c-1bf1-4095-9a86-5ec5ff945d2b"),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );

    expect(result).toEqual({ status: "stale-stage" });
    expectNoSideEffects(d);
    expect(d.discardUpload).not.toHaveBeenCalled();
  });

  it("checks the stage AFTER the window, and before the first side effect", async () => {
    const order: string[] = [];
    const d = deps({
      isWindowOpen: vi.fn(async () => {
        order.push("window");
        return true;
      }),
      readStage: vi.fn(async () => {
        order.push("stage");
        return DELIVERY_PROOF_STAGE_ID;
      }),
      uploadProof: vi.fn(async () => {
        order.push("upload");
        return { publicUrl: "https://storage/x.png", path: "account-1/x.png" };
      }),
    });

    await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(order).toEqual(["window", "stage", "upload"]);
  });

  it("fails closed when the stage cannot be read", async () => {
    const d = deps({ readStage: vi.fn(async () => null) });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(result).toEqual({ status: "stale-stage" });
    expectNoSideEffects(d);
  });

  it("fails closed when the stage read throws", async () => {
    const d = deps({
      readStage: vi.fn(async () => {
        throw new Error("network");
      }),
    });
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: draftFor("deal-1") },
      d,
    );
    expect(result).toEqual({ status: "stale-stage" });
    expectNoSideEffects(d);
  });

  it("does not re-read the stage on a stage-only retry", async () => {
    // The proof is already with the customer; the only thing left is
    // the update, and RLS plus the trigger handle that.
    const d = deps();
    await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1", { sentWamid: "wamid.SENT" }),
      },
      d,
    );
    expect(d.readStage).not.toHaveBeenCalled();
  });

  it("does not read the stage for a deal without a proof", async () => {
    const d = deps();
    await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: null },
      d,
    );
    expect(d.readStage).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------
// M-10 — the confirmation whose proof vanished
//
// Found in the manual gate: another session moved the deal while the
// confirmation dialog was open, `pruneStaleDrafts` dropped the draft,
// and the dialog stayed up still promising "se enviará la captura" —
// with a confirm button that had quietly become a plain "mark
// delivered". Nothing unsafe was sent, but a confirmation that does
// something other than what it says is a bug.
//
// `expectsProof` is what tells these two apart: "deliver this deal,
// it has no proof" versus "deliver this deal WITH the proof I was
// just shown". The second can never decay into the first.
// ---------------------------------------------------------------

describe("a confirmation that was shown a proof", () => {
  it("refuses when the draft vanished: stale-stage, and nothing else happens", async () => {
    const d = deps();
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: null, // pruned between opening the dialog and confirming
        expectsProof: true,
      },
      d,
    );

    expect(result).toEqual({ status: "stale-stage" });
    expect(d.uploadProof).not.toHaveBeenCalled();
    expect(d.sendProof).not.toHaveBeenCalled();
    // The critical one: the deal must NOT move. A silent plain
    // delivery is exactly the defect this guards.
    expect(d.moveToDelivered).not.toHaveBeenCalled();
    // Refused before any probe, too.
    expect(d.canSend).not.toHaveBeenCalled();
    expect(d.readStage).not.toHaveBeenCalled();
  });

  it("refuses even when the operator chose to skip the proof", async () => {
    // "Marcar entregada sin enviar captura" on a closed window still
    // came from a dialog that had a screenshot on it. If the draft is
    // gone, the deal moved, and the answer is the same.
    const d = deps();
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: null,
        skipProof: true,
        expectsProof: true,
      },
      d,
    );

    expect(result).toEqual({ status: "stale-stage" });
    expect(d.moveToDelivered).not.toHaveBeenCalled();
  });

  it("still delivers normally when the draft is there", async () => {
    const d = deps();
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1"),
        expectsProof: true,
      },
      d,
    );
    expect(result).toMatchObject({ status: "delivered", proofSent: true });
    expect(d.sendProof).toHaveBeenCalledTimes(1);
  });

  it("still honours a deliberate skip when the draft is there", async () => {
    const d = deps();
    const result = await deliverDeal(
      {
        dealId: "deal-1",
        conversationId: "conv-1",
        draft: draftFor("deal-1"),
        skipProof: true,
        expectsProof: true,
      },
      d,
    );
    expect(result).toEqual({ status: "delivered", proofSent: false });
    expect(d.sendProof).not.toHaveBeenCalled();
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
  });

  it("leaves the ordinary no-proof delivery untouched", async () => {
    // Without `expectsProof` this is a deal that simply has no
    // screenshot — today's path, and it must keep working.
    const d = deps();
    const result = await deliverDeal(
      { dealId: "deal-1", conversationId: "conv-1", draft: null },
      d,
    );
    expect(result).toEqual({ status: "delivered", proofSent: false });
    expect(d.moveToDelivered).toHaveBeenCalledTimes(1);
  });
});
