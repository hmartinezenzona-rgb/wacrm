import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sendMediaMessage, uploadMediaToMeta } from "./meta-api";

// Capture the JSON body each helper POSTs to Meta so we can assert the
// exact payload shape per media kind without hitting the network.
interface CapturedBody {
  type?: string;
  image?: Record<string, unknown>;
  video?: Record<string, unknown>;
  document?: Record<string, unknown>;
  audio?: Record<string, unknown>;
}
let captured: CapturedBody | null = null;

function okFetch() {
  return vi.fn(async (_url: string, init?: RequestInit) => {
    captured = init?.body ? (JSON.parse(init.body as string) as CapturedBody) : null;
    return {
      ok: true,
      json: async () => ({ messages: [{ id: "wamid.TEST" }] }),
    } as Response;
  });
}

const BASE = {
  phoneNumberId: "test-phone",
  accessToken: "test-token",
  to: "1234567890",
  link: "https://cdn.example.com/file",
} as const;

describe("sendMediaMessage — payload shape", () => {
  beforeEach(() => {
    captured = null;
    vi.stubGlobal("fetch", okFetch());
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends image with a caption and no filename", async () => {
    await sendMediaMessage({ ...BASE, kind: "image", caption: "hello", filename: "x.png" });
    expect(captured?.type).toBe("image");
    expect(captured?.image).toEqual({ link: BASE.link, caption: "hello" });
    expect(captured?.image?.filename).toBeUndefined();
  });

  it("sends document with both caption and filename", async () => {
    await sendMediaMessage({
      ...BASE,
      kind: "document",
      caption: "invoice",
      filename: "invoice.pdf",
    });
    expect(captured?.type).toBe("document");
    expect(captured?.document).toEqual({
      link: BASE.link,
      caption: "invoice",
      filename: "invoice.pdf",
    });
  });

  it("sends audio with NO caption and NO filename (Meta rejects both)", async () => {
    await sendMediaMessage({
      ...BASE,
      kind: "audio",
      caption: "should be dropped",
      filename: "voice.ogg",
    });
    expect(captured?.type).toBe("audio");
    expect(captured?.audio).toEqual({ link: BASE.link });
  });

  it("throws when no link is provided", async () => {
    await expect(
      sendMediaMessage({ ...BASE, link: "", kind: "image" }),
    ).rejects.toThrow(/requires a link/);
  });

  // ----------------------------------------------------------
  // Sending by media_id instead of link. A `link` makes Meta fetch the
  // file at send time; when that fetch fails, Meta has ALREADY accepted
  // the message and returned a wamid, and the failure only surfaces
  // minutes later as a `failed` status. That is what cost a customer
  // her transfer receipt on 24-ago-2026 while the deal was closed as
  // delivered. With an id the bytes are already at Meta.
  // ----------------------------------------------------------
  it("sends by id when a mediaId is given, with no link in the payload", async () => {
    await sendMediaMessage({
      ...BASE,
      kind: "image",
      mediaId: "media-123",
      caption: "comprobante",
    });
    expect(captured?.image).toEqual({ id: "media-123", caption: "comprobante" });
    expect(captured?.image?.link).toBeUndefined();
  });

  it("prefers the mediaId over the link when both are present", async () => {
    await sendMediaMessage({ ...BASE, kind: "image", mediaId: "media-123" });
    expect(captured?.image).toEqual({ id: "media-123" });
  });

  it("still accepts a mediaId with no link at all", async () => {
    await sendMediaMessage({
      ...BASE,
      link: undefined,
      kind: "document",
      mediaId: "media-9",
      filename: "recibo.pdf",
    });
    expect(captured?.document).toEqual({ id: "media-9", filename: "recibo.pdf" });
  });
});

describe("uploadMediaToMeta", () => {
  let lastUpload: { url: string; init?: RequestInit } | null = null;

  beforeEach(() => {
    lastUpload = null;
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function uploadFetch(response: { ok: boolean; body: unknown }) {
    return vi.fn(async (url: string, init?: RequestInit) => {
      lastUpload = { url, init };
      return {
        ok: response.ok,
        status: response.ok ? 200 : 400,
        json: async () => response.body,
      } as Response;
    });
  }

  const ARGS = {
    phoneNumberId: "test-phone",
    accessToken: "test-token",
    bytes: new Uint8Array([1, 2, 3]).buffer,
    mimeType: "image/png",
    fileName: "captura.png",
  };

  it("posts the file to /media and returns the id", async () => {
    vi.stubGlobal("fetch", uploadFetch({ ok: true, body: { id: "media-abc" } }));

    const { mediaId } = await uploadMediaToMeta(ARGS);

    expect(mediaId).toBe("media-abc");
    expect(lastUpload?.url).toContain("/test-phone/media");
    const form = lastUpload?.init?.body as FormData;
    expect(form.get("messaging_product")).toBe("whatsapp");
    expect(form.get("type")).toBe("image/png");
    expect(form.get("file")).toBeInstanceOf(Blob);
  });

  it("does NOT set Content-Type by hand — FormData owns the boundary", async () => {
    vi.stubGlobal("fetch", uploadFetch({ ok: true, body: { id: "media-abc" } }));
    await uploadMediaToMeta(ARGS);

    const headers = (lastUpload?.init?.headers ?? {}) as Record<string, string>;
    expect(headers.Authorization).toBe("Bearer test-token");
    expect(headers["Content-Type"]).toBeUndefined();
  });

  it("throws when Meta answers without an id", async () => {
    vi.stubGlobal("fetch", uploadFetch({ ok: true, body: {} }));
    await expect(uploadMediaToMeta(ARGS)).rejects.toThrow(/did not return an id/);
  });

  it("surfaces Meta's error message on a rejected upload", async () => {
    vi.stubGlobal(
      "fetch",
      uploadFetch({ ok: false, body: { error: { message: "Unsupported media type" } } }),
    );
    await expect(uploadMediaToMeta(ARGS)).rejects.toThrow(/Unsupported media type/);
  });
});
