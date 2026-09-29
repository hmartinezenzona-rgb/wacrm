import { describe, it, expect, vi } from "vitest";
import {
  sendBeneficiaryProofs,
  type BeneficiaryProofDeps,
  type BeneficiaryProofItem,
} from "./send-beneficiary-proofs";
import type { SendProofOutcome } from "./deliver-with-proof";

const PNG_HEADER = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

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

function item(over: Partial<BeneficiaryProofItem> = {}): BeneficiaryProofItem {
  return {
    beneficiaryId: over.beneficiaryId ?? "ben-1",
    file: pngFile(),
    kind: "png",
    caption: "",
    ...over,
  };
}

function deps(over: Partial<BeneficiaryProofDeps> = {}): BeneficiaryProofDeps {
  return {
    conversationId: "conv-1",
    uploadProof: vi.fn(async (_file: File, uploadName: string) => ({
      publicUrl: `https://storage.example/account-1/1234-${uploadName}`,
      path: `account-1/1234-${uploadName}`,
    })),
    sendProof: vi.fn(async (): Promise<SendProofOutcome> => ({ ok: true, wamid: "wamid.DEFAULT" })),
    discardUpload: vi.fn(async () => {}),
    registerProof: vi.fn(async () => ({ ok: true, missing: 0 })),
    ...over,
  };
}

describe("sendBeneficiaryProofs", () => {
  it("sends each image, then registers it, in beneficiary order", async () => {
    const order: string[] = [];
    const d = deps({
      uploadProof: vi.fn(async (_f, name) => {
        order.push(`upload:${name}`);
        return { publicUrl: `https://x/${name}`, path: `account-1/${name}` };
      }),
      sendProof: vi.fn(async ({ caption }): Promise<SendProofOutcome> => {
        order.push(`send:${caption}`);
        return { ok: true, wamid: `wamid.${caption || "none"}` };
      }),
      registerProof: vi.fn(async (beneficiaryId) => {
        order.push(`register:${beneficiaryId}`);
        return { ok: true, missing: 0 };
      }),
    });

    const items = [
      item({ beneficiaryId: "ben-1", caption: "Ana" }),
      item({ beneficiaryId: "ben-2", caption: "Beto" }),
    ];

    const result = await sendBeneficiaryProofs(items, d);

    expect(result.status).toBe("sent");
    expect(order).toEqual([
      "upload:prueba-entrega.png",
      "send:Ana",
      "register:ben-1",
      "upload:prueba-entrega.png",
      "send:Beto",
      "register:ben-2",
    ]);
  });

  it("carries wamid/path into the register call and trims the caption", async () => {
    const d = deps({
      sendProof: vi.fn(async (): Promise<SendProofOutcome> => ({ ok: true, wamid: "wamid.ABC" })),
    });
    await sendBeneficiaryProofs([item({ caption: "  Ana  " })], d);

    expect(d.registerProof).toHaveBeenCalledWith("ben-1", {
      wamid: "wamid.ABC",
      path: "account-1/1234-prueba-entrega.png",
      caption: "Ana",
    });
  });

  it("omits caption from the register call when there is none", async () => {
    const d = deps();
    await sendBeneficiaryProofs([item({ caption: "" })], d);
    expect(d.registerProof).toHaveBeenCalledWith(
      "ben-1",
      expect.objectContaining({ caption: undefined }),
    );
  });

  it("returns every item marked sent, carrying wamid and path", async () => {
    const d = deps({
      sendProof: vi.fn(async (): Promise<SendProofOutcome> => ({ ok: true, wamid: "wamid.ABC" })),
    });
    const result = await sendBeneficiaryProofs([item()], d);
    expect(result).toMatchObject({
      status: "sent",
      items: [{ beneficiaryId: "ben-1", sentWamid: "wamid.ABC", sentPath: "account-1/1234-prueba-entrega.png" }],
    });
  });

  describe("a failure on the second beneficiary's image", () => {
    it("stops there, keeping the first as sent, and never registers the second", async () => {
      const d = deps({
        sendProof: vi.fn(async ({ caption }): Promise<SendProofOutcome> => {
          if (caption === "Beto") return { ok: false, outcome: "not-sent", message: "Meta 131047" };
          return { ok: true, wamid: "wamid.ANA" };
        }),
      });

      const items = [
        item({ beneficiaryId: "ben-1", caption: "Ana" }),
        item({ beneficiaryId: "ben-2", caption: "Beto" }),
      ];
      const result = await sendBeneficiaryProofs(items, d);

      expect(result.status).toBe("failed");
      if (result.status !== "failed") throw new Error("unreachable");
      expect(result.beneficiaryId).toBe("ben-2");
      expect(result.message).toBe("Meta 131047");
      expect(result.items[0]).toMatchObject({ beneficiaryId: "ben-1", sentWamid: "wamid.ANA" });
      expect(result.items[1]!.sentWamid).toBeUndefined();
      expect(d.registerProof).toHaveBeenCalledTimes(1);
      expect(d.registerProof).toHaveBeenCalledWith("ben-1", expect.anything());
    });

    it("discards the failed upload for a clean not-sent failure", async () => {
      const d = deps({
        sendProof: vi.fn(async (): Promise<SendProofOutcome> => ({
          ok: false,
          outcome: "not-sent",
          message: "Meta 400",
        })),
      });
      await sendBeneficiaryProofs([item()], d);
      expect(d.discardUpload).toHaveBeenCalledWith("account-1/1234-prueba-entrega.png");
    });

    it("a retry does not resend the already-sent beneficiary, only the failed one", async () => {
      const d = deps({
        sendProof: vi.fn(async ({ caption }): Promise<SendProofOutcome> => {
          if (caption === "Beto") return { ok: true, wamid: "wamid.BETO" };
          throw new Error("must not resend ben-1");
        }),
      });

      // ben-1 already sent in a previous attempt (its draft carries sentWamid).
      const items = [
        item({ beneficiaryId: "ben-1", caption: "Ana", sentWamid: "wamid.ANA", sentPath: "account-1/ana.png" }),
        item({ beneficiaryId: "ben-2", caption: "Beto" }),
      ];

      const result = await sendBeneficiaryProofs(items, d);

      expect(result.status).toBe("sent");
      expect(d.uploadProof).toHaveBeenCalledTimes(1);
      expect(d.sendProof).toHaveBeenCalledTimes(1);
      expect(d.registerProof).toHaveBeenNthCalledWith(1, "ben-1", {
        wamid: "wamid.ANA",
        path: "account-1/ana.png",
        caption: "Ana",
      });
      expect(d.registerProof).toHaveBeenNthCalledWith(2, "ben-2", expect.objectContaining({ wamid: "wamid.BETO" }));
    });
  });

  describe("a failure to register", () => {
    it("stops without touching the storage object, and marks the item as sent so a retry does not resend", async () => {
      const d = deps({
        sendProof: vi.fn(async (): Promise<SendProofOutcome> => ({ ok: true, wamid: "wamid.ABC" })),
        registerProof: vi.fn(async () => ({ ok: false, message: "operation is not ready to transfer" })),
      });
      const result = await sendBeneficiaryProofs([item()], d);

      expect(result.status).toBe("failed");
      if (result.status !== "failed") throw new Error("unreachable");
      expect(result.phase).toBe("register");
      expect(result.items[0]).toMatchObject({ sentWamid: "wamid.ABC" });
      expect(d.discardUpload).not.toHaveBeenCalled();
    });

    it("a retry after a register failure only re-registers, never re-sends", async () => {
      const registerProof = vi
        .fn()
        .mockResolvedValueOnce({ ok: false, message: "transient" })
        .mockResolvedValueOnce({ ok: true, missing: 0 });
      const d = deps({ registerProof });

      const first = await sendBeneficiaryProofs([item()], d);
      expect(first.status).toBe("failed");

      const retryItems = first.status === "failed" ? first.items : [];
      const second = await sendBeneficiaryProofs(retryItems, d);

      expect(second.status).toBe("sent");
      expect(d.uploadProof).toHaveBeenCalledTimes(1);
      expect(d.sendProof).toHaveBeenCalledTimes(1);
      expect(registerProof).toHaveBeenCalledTimes(2);
    });
  });

  it("treats a thrown send as unconfirmed and does not mark the item sent (a retry may resend)", async () => {
    const d = deps({
      sendProof: vi.fn(async () => {
        throw new Error("network error");
      }),
    });
    const result = await sendBeneficiaryProofs([item()], d);
    expect(result.status).toBe("failed");
    if (result.status !== "failed") throw new Error("unreachable");
    expect(result.items[0]!.sentWamid).toBeUndefined();
    expect(d.registerProof).not.toHaveBeenCalled();
  });

  it("refuses an invalid file before uploading anything", async () => {
    const badFile = {
      type: "image/png",
      size: 10,
      arrayBuffer: async () => new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]).buffer,
    } as unknown as File;
    const d = deps();
    const result = await sendBeneficiaryProofs([item({ file: badFile })], d);

    expect(result.status).toBe("failed");
    if (result.status !== "failed") throw new Error("unreachable");
    expect(result.phase).toBe("invalid-file");
    expect(d.uploadProof).not.toHaveBeenCalled();
  });
});
