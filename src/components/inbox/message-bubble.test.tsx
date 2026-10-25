// @vitest-environment jsdom
// Stored chat-media URLs are public-bucket URLs; the bubble must display
// them through the same-origin proxy so it keeps working once the bucket is private.
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "@/types";
import { MessageBubble } from "./message-bubble";
import { resetSignedMediaCache } from "@/lib/storage/signed-media";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

const ACCT = "3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c";
const STORED = (name: string) =>
  `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${ACCT}/${name}`;
const PROXIED = (name: string) => `/api/chat-media/account-${ACCT}/${name}`;

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

describe("MessageBubble media sources", () => {
  // Signing is attempted first; the proxy is the fallback. Each test decides
  // what the signer answers, and a failure is the default so no test hits the
  // network.
  beforeEach(() => {
    resetSignedMediaCache();
    vi.stubGlobal("fetch", vi.fn(async () => ({ ok: false, json: async () => ({}) }) as Response));
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    resetSignedMediaCache();
  });

  it("image: public chat-media URL -> signed CDN URL when the signer answers", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => ({
      ok: true,
      json: async () => ({ signed: { [STORED("1-wa-1.jpg")]: "https://signed/1-wa-1.jpg" }, expiresIn: 3600 }),
    }) as Response));
    const { node, unmount } = await render({ content_type: "image", media_url: STORED("1-wa-1.jpg") });
    await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
    expect(node.querySelector("img")?.getAttribute("src")).toBe("https://signed/1-wa-1.jpg");
    await unmount();
  });

  it("image: falls back to the proxy when signing fails", async () => {
    const { node, unmount } = await render({ content_type: "image", media_url: STORED("1-wa-1.jpg") });
    await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
    expect(node.querySelector("img")?.getAttribute("src")).toBe(PROXIED("1-wa-1.jpg"));
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

  it("video, audio and document use the proxy too", async () => {
    const v = await render({ content_type: "video", media_url: STORED("2.mp4") });
    expect(v.node.querySelector("video")?.getAttribute("src")).toBe(PROXIED("2.mp4"));
    await v.unmount();

    const a = await render({ content_type: "audio", media_url: STORED("3.ogg") });
    expect(a.node.querySelector("audio")?.getAttribute("src")).toBe(PROXIED("3.ogg"));
    await a.unmount();

    const d = await render({ content_type: "document", media_url: STORED("4.pdf") });
    expect(d.node.querySelector("a")?.getAttribute("href")).toBe(PROXIED("4.pdf"));
    await d.unmount();
  });

  it("non-chat-media URLs are left alone", async () => {
    const a = await render({ content_type: "audio", media_url: "https://cdn.example.com/a.ogg" });
    expect(a.node.querySelector("audio")?.getAttribute("src")).toBe("https://cdn.example.com/a.ogg");
    await a.unmount();
  });
});
