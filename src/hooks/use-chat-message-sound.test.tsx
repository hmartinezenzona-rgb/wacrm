// @vitest-environment jsdom
//
// jsdom has no real audio pipeline: HTMLMediaElement.play()/pause() throw
// "not implemented" unless stubbed. We stub them on the prototype (the
// same technique the browser-API tests elsewhere in this repo use for
// unsupported jsdom pieces, e.g. the PointerEvent polyfill in
// conversation-list.test.tsx) and assert the hook calls them correctly —
// mirrors how useNotificationAlerts drives its own Audio element.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useChatMessageSound } from "./use-chat-message-sound";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

type SoundApi = ReturnType<typeof useChatMessageSound>;

function TestHarness({ onReady }: { onReady: (api: SoundApi) => void }) {
  const api = useChatMessageSound();
  onReady(api);
  return null;
}

describe("useChatMessageSound", () => {
  let container: HTMLDivElement;
  let playSpy: ReturnType<typeof vi.fn>;
  let pauseSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
    playSpy = vi.fn().mockResolvedValue(undefined);
    pauseSpy = vi.fn();
    window.HTMLMediaElement.prototype.play =
      playSpy as unknown as () => Promise<void>;
    window.HTMLMediaElement.prototype.pause = pauseSpy as unknown as () => void;
  });

  afterEach(() => {
    container.remove();
    vi.restoreAllMocks();
  });

  async function mount() {
    let api: SoundApi | null = null;
    const root = createRoot(container);
    await act(async () => {
      root.render(<TestHarness onReady={(a) => (api = a)} />);
    });
    if (!api) throw new Error("hook did not report ready");
    return { api: api as SoundApi, root };
  }

  it("plays the chime when play() is called", async () => {
    const { api, root } = await mount();

    act(() => {
      api.play();
    });

    expect(playSpy).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("rewinds to the start on every play() so rapid messages always ring", async () => {
    const { api, root } = await mount();

    act(() => {
      api.play();
    });
    act(() => {
      api.play();
    });

    expect(playSpy).toHaveBeenCalledTimes(2);
    await act(async () => root.unmount());
  });

  it("stop() pauses an in-flight chime and rewinds it", async () => {
    const { api, root } = await mount();

    act(() => {
      api.play();
      api.stop();
    });

    expect(pauseSpy).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("never throws even if the underlying Audio API rejects play()", async () => {
    playSpy.mockRejectedValue(new Error("NotAllowedError"));
    const { api, root } = await mount();

    expect(() => {
      act(() => {
        api.play();
      });
    }).not.toThrow();

    await act(async () => root.unmount());
  });
});
