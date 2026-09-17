// Slice: panel-26 (readiness). The single `/api/remittance-operations`
// round trip (see route.ts) can't get faster — it can only start
// earlier. This module fires it on hover/focus of a conversation row
// (conversation-list.tsx) and caches the result briefly so the panel
// container can paint from it on the FIRST render instead of waiting.
//
// Fake timers + `vi.setSystemTime` drive the TTL assertions — never a
// real sleep, and never a read of the real clock (this repo has already
// been bitten twice by tests that measured the environment instead of
// the code; see session-window.parity.test.ts's header).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  __resetPanelPrefetchForTests,
  prefetchConversationOperations,
  readPrefetchedConversationOperations,
} from "./panel-prefetch";
import type { ConversationOperationsRead } from "./types";

function operationsRead(id = "op-1"): ConversationOperationsRead {
  return {
    resolverState: "unica",
    resolverOperationId: id,
    resolverCandidateCount: 1,
    operations: [],
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}

// Drains the microtask queue generously (fetch -> .then -> response.json()
// -> cache write each need their own tick) without guessing an exact
// count — same style as route.test.ts's receipts-parallelism test.
async function flush() {
  for (let i = 0; i < 20; i++) {
    await Promise.resolve();
  }
}

beforeEach(() => {
  __resetPanelPrefetchForTests();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  __resetPanelPrefetchForTests();
});

describe("prefetchConversationOperations / readPrefetchedConversationOperations", () => {
  it("fires the same GET the panel container uses, and caches the result for reading back", async () => {
    const data = operationsRead("conv-1");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);

    prefetchConversationOperations("conv-1");
    await flush();

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/remittance-operations?conversationId=conv-1",
      expect.objectContaining({ cache: "no-store" }),
    );
    expect(readPrefetchedConversationOperations("conv-1")).toEqual(data);
  });

  it("never issues a second request for the same id while one is already in flight", async () => {
    let resolveFetch!: (response: Response) => void;
    const fetchMock = vi.fn(
      () => new Promise<Response>((resolve) => { resolveFetch = resolve; }),
    );
    vi.stubGlobal("fetch", fetchMock);

    prefetchConversationOperations("conv-1");
    prefetchConversationOperations("conv-1");
    prefetchConversationOperations("conv-1");
    expect(fetchMock).toHaveBeenCalledTimes(1);

    resolveFetch(jsonResponse(operationsRead("conv-1")));
    await flush();

    expect(readPrefetchedConversationOperations("conv-1")).toEqual(operationsRead("conv-1"));
  });

  it("returns a cached entry before the TTL, and null once 30s have passed", async () => {
    const data = operationsRead("conv-1");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));
    vi.useFakeTimers();
    const t0 = new Date("2026-09-17T12:00:00Z").getTime();
    vi.setSystemTime(t0);

    prefetchConversationOperations("conv-1");
    await flush();
    expect(readPrefetchedConversationOperations("conv-1")).toEqual(data);

    vi.setSystemTime(t0 + 29_000);
    expect(readPrefetchedConversationOperations("conv-1")).toEqual(data);

    vi.setSystemTime(t0 + 30_001);
    expect(readPrefetchedConversationOperations("conv-1")).toBeNull();
  });

  it("returns null for an id that was never prefetched", () => {
    expect(readPrefetchedConversationOperations("never-seen")).toBeNull();
  });

  it("keeps at most ~10 entries, dropping the oldest first", async () => {
    const fetchMock = vi.fn((url: string) => {
      const id = new URL(url, "http://localhost").searchParams.get("conversationId")!;
      return Promise.resolve(jsonResponse(operationsRead(id)));
    });
    vi.stubGlobal("fetch", fetchMock);

    for (let i = 1; i <= 11; i++) {
      prefetchConversationOperations(`conv-${i}`);
      await flush();
    }

    // The 11th prefetch pushed the bound past 10 — the oldest (conv-1)
    // must be gone, the newest must survive.
    expect(readPrefetchedConversationOperations("conv-1")).toBeNull();
    expect(readPrefetchedConversationOperations("conv-11")).toEqual(operationsRead("conv-11"));
    expect(readPrefetchedConversationOperations("conv-6")).toEqual(operationsRead("conv-6"));
  });

  it("self-gates after the first 404: every later call is a no-op (zero further fetch calls)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 404 }));
    vi.stubGlobal("fetch", fetchMock);

    prefetchConversationOperations("conv-1");
    await flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(readPrefetchedConversationOperations("conv-1")).toBeNull();

    prefetchConversationOperations("conv-2");
    prefetchConversationOperations("conv-3");
    await flush();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not cache a non-404 failure response", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse({ error: "boom" }, 500)));

    prefetchConversationOperations("conv-1");
    await flush();

    expect(readPrefetchedConversationOperations("conv-1")).toBeNull();
  });

  it("never throws and never caches on a network rejection", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network down")));

    expect(() => prefetchConversationOperations("conv-1")).not.toThrow();
    await flush();

    expect(readPrefetchedConversationOperations("conv-1")).toBeNull();
  });
});
