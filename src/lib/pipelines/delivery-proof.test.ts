import { describe, it, expect } from "vitest";
import {
  PROOF_MAX_BYTES,
  detectImageKind,
  draftBelongsTo,
  pickPastedImage,
  proofUploadName,
  validateProofFile,
  type DeliveryProofDraft,
} from "./delivery-proof";

// ---------------------------------------------------------------
// Byte fixtures. Real headers, padded to a plausible length.
// ---------------------------------------------------------------

const PNG_HEADER = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const JPEG_HEADER = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10];
// "RIFF" + 4 size bytes + "WEBP"
const WEBP_HEADER = [
  0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
];
const GIF_HEADER = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
// HEIC: an ISO-BMFF box — "....ftypheic"
const HEIC_HEADER = [
  0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63,
];

function bytes(header: number[], totalSize = 64): Uint8Array {
  const out = new Uint8Array(Math.max(totalSize, header.length));
  out.set(header, 0);
  return out;
}

/**
 * A stand-in for a browser `File`. vitest runs under `environment:
 * "node"`, so this asserts the module really is DOM-free.
 *
 * `declaredSize` lets a test claim a size without allocating it —
 * that is how the 5 MB rejection is checked without a 5 MB buffer.
 */
function fakeFile(
  type: string,
  header: number[],
  declaredSize?: number,
): { type: string; size: number; arrayBuffer(): Promise<ArrayBuffer> } {
  const data = bytes(header);
  return {
    type,
    size: declaredSize ?? data.byteLength,
    arrayBuffer: async () => data.buffer.slice(0) as ArrayBuffer,
  };
}

// ---------------------------------------------------------------

describe("detectImageKind", () => {
  it("recognises the three accepted formats", () => {
    expect(detectImageKind(bytes(PNG_HEADER))).toBe("png");
    expect(detectImageKind(bytes(JPEG_HEADER))).toBe("jpeg");
    expect(detectImageKind(bytes(WEBP_HEADER))).toBe("webp");
  });

  it("rejects formats outside the MVP", () => {
    expect(detectImageKind(bytes(GIF_HEADER))).toBeNull();
    expect(detectImageKind(bytes(HEIC_HEADER))).toBeNull();
  });

  it("does not mistake other RIFF containers for WEBP", () => {
    // "RIFF" + size + "AVI " — same first four bytes as a WEBP.
    const avi = [
      0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x41, 0x56, 0x49, 0x20,
    ];
    expect(detectImageKind(bytes(avi))).toBeNull();
  });

  it("returns null for a buffer too short to identify", () => {
    expect(detectImageKind(new Uint8Array([0x89, 0x50]))).toBeNull();
    expect(detectImageKind(new Uint8Array())).toBeNull();
  });
});

describe("proofUploadName", () => {
  it("carries nothing about the customer, sender or amount", () => {
    expect(proofUploadName("png")).toBe("prueba-entrega.png");
    expect(proofUploadName("jpeg")).toBe("prueba-entrega.jpg");
    expect(proofUploadName("webp")).toBe("prueba-entrega.webp");
  });
});

describe("validateProofFile", () => {
  // DP-02 / DP-03
  it("accepts PNG, JPEG and WEBP", async () => {
    await expect(validateProofFile(fakeFile("image/png", PNG_HEADER))).resolves
      .toMatchObject({ ok: true, kind: "png", uploadName: "prueba-entrega.png" });
    await expect(
      validateProofFile(fakeFile("image/jpeg", JPEG_HEADER)),
    ).resolves.toMatchObject({ ok: true, kind: "jpeg" });
    await expect(
      validateProofFile(fakeFile("image/webp", WEBP_HEADER)),
    ).resolves.toMatchObject({ ok: true, kind: "webp" });
  });

  // DP-04
  it("rejects HEIC and GIF on their declared type", async () => {
    await expect(
      validateProofFile(fakeFile("image/heic", HEIC_HEADER)),
    ).resolves.toEqual({ ok: false, reason: "mime" });
    await expect(
      validateProofFile(fakeFile("image/gif", GIF_HEADER)),
    ).resolves.toEqual({ ok: false, reason: "mime" });
  });

  it("rejects a non-image outright", async () => {
    await expect(
      validateProofFile(fakeFile("application/pdf", [0x25, 0x50, 0x44, 0x46])),
    ).resolves.toEqual({ ok: false, reason: "mime" });
  });

  // DP-05
  it("rejects anything over 5 MB", async () => {
    const big = fakeFile("image/png", PNG_HEADER, PROOF_MAX_BYTES + 1);
    await expect(validateProofFile(big)).resolves.toEqual({
      ok: false,
      reason: "size",
    });
  });

  it("accepts a file exactly at the limit", async () => {
    const edge = fakeFile("image/png", PNG_HEADER, PROOF_MAX_BYTES);
    await expect(validateProofFile(edge)).resolves.toMatchObject({ ok: true });
  });

  // DP-06
  it("rejects a file whose bytes contradict its declared type", async () => {
    // A GIF renamed to .png and announced as image/png.
    await expect(
      validateProofFile(fakeFile("image/png", GIF_HEADER)),
    ).resolves.toEqual({ ok: false, reason: "signature" });
  });

  it("rejects a real PNG announced as JPEG", async () => {
    // The bucket stores the declared Content-Type, so a mismatch
    // would hand Meta a file that contradicts its own header.
    await expect(
      validateProofFile(fakeFile("image/jpeg", PNG_HEADER)),
    ).resolves.toEqual({ ok: false, reason: "signature" });
  });

  it("rejects an empty file and a missing one", async () => {
    await expect(
      validateProofFile(fakeFile("image/png", PNG_HEADER, 0)),
    ).resolves.toEqual({ ok: false, reason: "empty" });
    await expect(validateProofFile(null)).resolves.toEqual({
      ok: false,
      reason: "empty",
    });
  });

  it("checks the declared type before reading any bytes", async () => {
    // A 4 GB video must not be pulled into memory to be refused.
    let read = false;
    const huge = {
      type: "video/mp4",
      size: 4_000_000_000,
      arrayBuffer: async () => {
        read = true;
        return new ArrayBuffer(0);
      },
    };
    await expect(validateProofFile(huge)).resolves.toEqual({
      ok: false,
      reason: "mime",
    });
    expect(read).toBe(false);
  });

  it("treats an unreadable file as invalid rather than throwing", async () => {
    const broken = {
      type: "image/png",
      size: 100,
      arrayBuffer: async () => {
        throw new Error("read error");
      },
    };
    await expect(validateProofFile(broken)).resolves.toEqual({
      ok: false,
      reason: "signature",
    });
  });
});

describe("pickPastedImage", () => {
  // DP-01
  it("returns null for a text-only paste so the browser handles it", () => {
    expect(pickPastedImage({ files: [] })).toBeNull();
    expect(pickPastedImage({ files: null })).toBeNull();
    expect(pickPastedImage(null)).toBeNull();
  });

  it("returns the first image on the clipboard", () => {
    const png = { type: "image/png" } as File;
    expect(pickPastedImage({ files: [png] })).toBe(png);
  });

  it("skips non-image attachments", () => {
    const pdf = { type: "application/pdf" } as File;
    const png = { type: "image/png" } as File;
    expect(pickPastedImage({ files: [pdf, png] })).toBe(png);
    expect(pickPastedImage({ files: [pdf] })).toBeNull();
  });

  it("lets an unsupported image type through to be rejected with a reason", () => {
    // Catching HEIC here would give a silent no-op paste; it is
    // better to accept it and then explain why it is refused.
    const heic = { type: "image/heic" } as File;
    expect(pickPastedImage({ files: [heic] })).toBe(heic);
  });
});

describe("draftBelongsTo", () => {
  const draft = { dealId: "deal-a" } as DeliveryProofDraft;

  // DP-17
  it("only matches its own deal", () => {
    expect(draftBelongsTo(draft, "deal-a")).toBe(true);
    expect(draftBelongsTo(draft, "deal-b")).toBe(false);
  });

  it("is false for a missing draft or a missing deal id", () => {
    expect(draftBelongsTo(null, "deal-a")).toBe(false);
    expect(draftBelongsTo(draft, "")).toBe(false);
  });
});
