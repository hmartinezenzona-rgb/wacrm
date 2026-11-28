// @vitest-environment jsdom
// Slice 2: bubbles paint from the signed Storage URL first. The byte proxy is
// only the fallback when signing fails, images are lazy with a reserved box,
// audio/video transfer nothing before play, and a load error re-signs once.
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "@/types";
import { MessageBubble } from "./message-bubble";
import { resetSignedMediaCache, seedSignedMedia } from "@/lib/storage/signed-media";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

const ACCT = "3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c";
const STORED = (name: string) =>
  `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/${name}`;
const PROXIED = (name: string) => `/api/chat-media/account-${ACCT}/${name}`;

function signedResponse(map: Record<string, string>) {
  return {
    ok: true,
    json: async () => ({ signed: map, expiresIn: 3600 }),
  } as Response;
}

function failingResponse() {
  return { ok: false, json: async () => ({}) } as Response;
}

async function render(over: Partial<Message>) {
  const message = {
    id: "m1",
    conversation_id: "c1",
    sender_type: "customer",
    status: "delivered",
    created_at: "2026-01-01T10:00:00Z",
    ...over,
  } as unknown as Message;
  const node = document.createElement("div");
  const root = createRoot(node);
  await act(async () => root.render(<MessageBubble message={message} />));
  return { node, unmount: () => act(async () => root.unmount()) };
}

async function settle(ms = 40) {
  await act(async () => {
    await new Promise((r) => setTimeout(r, ms));
  });
}

function fireError(node: HTMLElement, selector: string) {
  const el = node.querySelector(selector);
  if (!el) throw new Error(`missing ${selector}`);
  return el;
}

describe("MessageBubble media sources", () => {
  // Signing is attempted first; the proxy is the fallback. Each test decides
  // what the signer answers, and a failure is the default so no test hits the
  // network.
  beforeEach(() => {
    resetSignedMediaCache();
    vi.stubGlobal("fetch", vi.fn(async () => failingResponse()));
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    resetSignedMediaCache();
  });

  it("image: an already-seeded signed URL paints on the very first render with no sign request", async () => {
    const fetchMock = vi.fn(async () => failingResponse());
    vi.stubGlobal("fetch", fetchMock);
    seedSignedMedia({ [STORED("1-wa-1.jpg")]: "https://signed/seed.jpg" }, 3600);

    const { node, unmount } = await render({
      content_type: "image",
      media_url: STORED("1-wa-1.jpg"),
    });

    // No timer wait: the seeded value must be there at first paint.
    expect(node.querySelector("img")?.getAttribute("src")).toBe("https://signed/seed.jpg");
    expect(fetchMock).not.toHaveBeenCalled();
    await unmount();
  });

  it("image: signed CDN URL when signing answers, proxy only when it fails", async () => {
    vi.stubGlobal("fetch", vi.fn(async () =>
      signedResponse({ [STORED("1-wa-1.jpg")]: "https://signed/1-wa-1.jpg" }),
    ));
    const signed = await render({ content_type: "image", media_url: STORED("1-wa-1.jpg") });
    await settle();
    expect(signed.node.querySelector("img")?.getAttribute("src")).toBe("https://signed/1-wa-1.jpg");
    await signed.unmount();

    resetSignedMediaCache();
    vi.stubGlobal("fetch", vi.fn(async () => failingResponse()));
    const proxied = await render({ content_type: "image", media_url: STORED("1-wa-1.jpg") });
    await settle();
    expect(proxied.node.querySelector("img")?.getAttribute("src")).toBe(PROXIED("1-wa-1.jpg"));
    await proxied.unmount();
  });

  it("image: lazy, async-decoded, inside the reserved h-40 w-60 box", async () => {
    seedSignedMedia({ [STORED("1-wa-1.jpg")]: "https://signed/seed.jpg" }, 3600);
    const { node, unmount } = await render({
      content_type: "image",
      media_url: STORED("1-wa-1.jpg"),
    });
    const img = node.querySelector("img")!;
    expect(img.getAttribute("loading")).toBe("lazy");
    expect(img.getAttribute("decoding")).toBe("async");
    expect(img.className).toContain("h-40");
    expect(img.className).toContain("w-60");
    await unmount();
  });

  it("video, audio and document: never a /api/chat-media source before resolution", async () => {
    // A sign request that never settles: the bubble must stay on its placeholder.
    vi.stubGlobal("fetch", vi.fn(() => new Promise<Response>(() => {})));

    const v = await render({ content_type: "video", media_url: STORED("2.mp4") });
    expect(v.node.querySelector("video")).toBeNull();
    expect(v.node.querySelectorAll('[src^="/api/chat-media/"]')).toHaveLength(0);
    await v.unmount();

    const a = await render({ content_type: "audio", media_url: STORED("3.ogg") });
    expect(a.node.querySelector("audio")).toBeNull();
    expect(a.node.querySelectorAll('[src^="/api/chat-media/"]')).toHaveLength(0);
    await a.unmount();

    const d = await render({ content_type: "document", media_url: STORED("4.pdf") });
    expect(d.node.querySelector('a[href^="/api/chat-media/"]')).toBeNull();
    expect(d.node.querySelector("a")?.getAttribute("href")).toBeNull();
    await d.unmount();
  });

  it("video and audio: signed src and preload=none when signing answers", async () => {
    vi.stubGlobal("fetch", vi.fn(async () =>
      signedResponse({
        [STORED("2.mp4")]: "https://signed/2.mp4",
        [STORED("3.ogg")]: "https://signed/3.ogg",
      }),
    ));

    const v = await render({ content_type: "video", media_url: STORED("2.mp4") });
    await settle();
    const video = v.node.querySelector("video");
    expect(video?.getAttribute("src")).toBe("https://signed/2.mp4");
    expect(video?.getAttribute("preload")).toBe("none");
    await v.unmount();

    const a = await render({ content_type: "audio", media_url: STORED("3.ogg") });
    await settle();
    const audio = a.node.querySelector("audio");
    expect(audio?.getAttribute("src")).toBe("https://signed/3.ogg");
    expect(audio?.getAttribute("preload")).toBe("none");
    await a.unmount();
  });

  it("document: signed href when signing answers, no proxy first source", async () => {
    vi.stubGlobal("fetch", vi.fn(async () =>
      signedResponse({ [STORED("4.pdf")]: "https://signed/4.pdf" }),
    ));
    const { node, unmount } = await render({ content_type: "document", media_url: STORED("4.pdf") });
    await settle();
    expect(node.querySelector("a")?.getAttribute("href")).toBe("https://signed/4.pdf");
    await unmount();
  });

  it("video, audio and document fall back to the proxy when signing fails", async () => {
    const v = await render({ content_type: "video", media_url: STORED("2.mp4") });
    await settle();
    expect(v.node.querySelector("video")?.getAttribute("src")).toBe(PROXIED("2.mp4"));
    await v.unmount();

    const a = await render({ content_type: "audio", media_url: STORED("3.ogg") });
    await settle();
    expect(a.node.querySelector("audio")?.getAttribute("src")).toBe(PROXIED("3.ogg"));
    await a.unmount();

    const d = await render({ content_type: "document", media_url: STORED("4.pdf") });
    await settle();
    expect(d.node.querySelector("a")?.getAttribute("href")).toBe(PROXIED("4.pdf"));
    await d.unmount();
  });

  it("image: one error re-signs exactly once and then falls back", async () => {
    const fetchMock = vi.fn(async () => failingResponse());
    vi.stubGlobal("fetch", fetchMock);
    seedSignedMedia({ [STORED("5-wa-5.jpg")]: "https://signed/expired.jpg" }, 3600);

    const { node, unmount } = await render({
      content_type: "image",
      media_url: STORED("5-wa-5.jpg"),
    });
    expect(node.querySelector("img")?.getAttribute("src")).toBe("https://signed/expired.jpg");

    // The first error drops the stale signature and asks once for a new one.
    await act(async () => {
      fireError(node, "img").dispatchEvent(new Event("error"));
    });
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    // Signing failed, so the proxy is the fallback source.
    expect(node.querySelector("img")?.getAttribute("src")).toBe(PROXIED("5-wa-5.jpg"));

    // A second error must not sign again: the media is unavailable now.
    await act(async () => {
      fireError(node, "img").dispatchEvent(new Event("error"));
    });
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(node.querySelector("img")).toBeNull();
    await unmount();
  });

  it("image: Meta proxy URLs keep their authenticated-fetch path (not rewritten)", async () => {
    const fetchMock = vi.fn(async () => ({ ok: true, blob: async () => new Blob(["x"]) }) as Response);
    vi.stubGlobal("fetch", fetchMock);
    URL.createObjectURL = vi.fn(() => "blob:fake");
    const { unmount } = await render({ content_type: "image", media_url: "/api/whatsapp/media/777" });
    expect(fetchMock).toHaveBeenCalledWith("/api/whatsapp/media/777");
    await unmount();
    vi.unstubAllGlobals();
  });

  it("non-chat-media URLs are left alone", async () => {
    const a = await render({ content_type: "audio", media_url: "https://cdn.example.com/a.ogg" });
    await settle();
    expect(a.node.querySelector("audio")?.getAttribute("src")).toBe("https://cdn.example.com/a.ogg");
    await a.unmount();
  });
});
