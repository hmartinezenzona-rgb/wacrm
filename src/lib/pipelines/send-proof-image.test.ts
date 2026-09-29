// Tests for `sendProofImage`, extracted from the pipelines board's
// `runDelivery` so the `/api/whatsapp/send` call shape and the
// db_error+wamid → sent-not-recorded mapping can be unit-tested without a
// browser. Behaviour must match the code it was extracted from exactly,
// including that a thrown fetch is NOT caught here — `deliverDeal` is
// what turns that into "unconfirmed".

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sendProofImage } from "./send-proof-image";

function jsonResponse(body: unknown, ok: boolean, status = ok ? 200 : 400): Response {
  return {
    ok,
    status,
    json: () => Promise.resolve(body),
  } as Response;
}

beforeEach(() => {
  vi.stubGlobal("fetch", vi.fn());
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("sendProofImage", () => {
  it("POSTs to /api/whatsapp/send with an image payload", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ whatsapp_message_id: "wamid.ABC" }, true),
    );

    await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "Nombre del remitente: Juan",
    });

    expect(fetch).toHaveBeenCalledWith("/api/whatsapp/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        conversation_id: "conv-1",
        message_type: "image",
        media_url: "https://storage.example/x.png",
        content_text: "Nombre del remitente: Juan",
        panel_action: true,
      }),
    });
  });

  it("marks the request as a panel action (B2.2) — delivering a proof must not pause the bot", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({}, true));

    await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    const [, init] = vi.mocked(fetch).mock.calls[0]!;
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body.panel_action).toBe(true);
  });

  it("sends content_text as undefined when the caption is empty", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({}, true));

    await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    const [, init] = vi.mocked(fetch).mock.calls[0]!;
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body.content_text).toBeUndefined();
  });

  it("returns ok:true with the wamid on success", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ whatsapp_message_id: "wamid.ABC" }, true),
    );

    const result = await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    expect(result).toEqual({ ok: true, wamid: "wamid.ABC" });
  });

  it("maps a plain failure to not-sent", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ error: "Meta 131047" }, false, 400),
    );

    const result = await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    expect(result).toEqual({ ok: false, outcome: "not-sent", message: "Meta 131047" });
  });

  it("falls back to an HTTP status message when the error body has none", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({}, false, 500));

    const result = await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    expect(result).toEqual({ ok: false, outcome: "not-sent", message: "HTTP 500" });
  });

  it("maps db_error with a wamid to sent-not-recorded — Meta got it, WaCRM did not save it", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse(
        {
          error: "Message sent to Meta but failed to save to DB: timeout",
          code: "db_error",
          whatsapp_message_id: "wamid.SENT",
        },
        false,
        500,
      ),
    );

    const result = await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    expect(result).toEqual({
      ok: false,
      outcome: "sent-not-recorded",
      message: "Message sent to Meta but failed to save to DB: timeout",
      wamid: "wamid.SENT",
    });
  });

  it("treats a db_error WITHOUT a wamid as a plain not-sent failure", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ error: "db exploded", code: "db_error" }, false, 500),
    );

    const result = await sendProofImage({
      conversationId: "conv-1",
      mediaUrl: "https://storage.example/x.png",
      caption: "",
    });

    expect(result).toEqual({ ok: false, outcome: "not-sent", message: "db exploded" });
  });

  it("does not catch a thrown fetch — the caller decides it's unconfirmed", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("network error"));

    await expect(
      sendProofImage({
        conversationId: "conv-1",
        mediaUrl: "https://storage.example/x.png",
        caption: "",
      }),
    ).rejects.toThrow("network error");
  });
});
