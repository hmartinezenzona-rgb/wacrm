// @vitest-environment jsdom
//
// Slice 3 (ADR-5): the open conversation owns a filtered UPDATE channel.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

type Handler = (payload: unknown) => void;

interface Subscription {
  event: string;
  config: Record<string, unknown>;
  handler: Handler;
}

const hoisted = vi.hoisted(() => ({
  channels: [] as Array<{
    name: string;
    subscriptions: Subscription[];
    subscribe: ReturnType<typeof vi.fn>;
  }>,
  removeChannel: vi.fn(),
}));

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    channel: (name: string) => {
      const subscriptions: Subscription[] = [];
      const channel = {
        name,
        subscriptions,
        on: vi.fn((event: string, config: Record<string, unknown>, handler: Handler) => {
          subscriptions.push({ event, config, handler });
          return channel;
        }),
        subscribe: vi.fn(() => channel),
      };
      hoisted.channels.push(channel);
      return channel;
    },
    removeChannel: hoisted.removeChannel,
  }),
}));

import { useThreadRealtime } from "./use-thread-realtime";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

function Probe({
  conversationId,
  onUpdate,
}: {
  conversationId: string | null;
  onUpdate: (message: { id: string }) => void;
}) {
  useThreadRealtime(conversationId, onUpdate);
  return null;
}

let mounted: Array<{ unmount: () => void }> = [];

beforeEach(() => {
  hoisted.channels.length = 0;
  hoisted.removeChannel.mockClear();
});

afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((root) => root.unmount()));
  document.body.replaceChildren();
});

async function mount(conversationId: string | null, onUpdate = vi.fn()) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(React.createElement(Probe, { conversationId, onUpdate })),
  );
  mounted.push(root);
  return { root, onUpdate };
}

describe("useThreadRealtime", () => {
  it("subscribes UPDATEs filtered to the open conversation", async () => {
    await mount("c1");

    expect(hoisted.channels).toHaveLength(1);
    const channel = hoisted.channels[0];
    expect(channel.name).toBe("thread:c1");
    expect(channel.subscriptions).toHaveLength(1);
    expect(channel.subscriptions[0].event).toBe("postgres_changes");
    expect(channel.subscriptions[0].config).toEqual({
      event: "UPDATE",
      schema: "public",
      table: "messages",
      filter: "conversation_id=eq.c1",
    });
  });

  it("delivers the updated row to the callback", async () => {
    const { onUpdate } = await mount("c1");
    const subscription = hoisted.channels[0].subscriptions[0];
    const row = { id: "m1", media_status: "ready" };

    await act(async () => subscription.handler({ eventType: "UPDATE", new: row, old: {} }));

    expect(onUpdate).toHaveBeenCalledWith(row);
  });

  it("tears the old channel down and scopes a new one when the conversation changes", async () => {
    const { root } = await mount("c1");
    const first = hoisted.channels[0];

    await act(async () =>
      root.render(React.createElement(Probe, { conversationId: "c2", onUpdate: vi.fn() })),
    );

    expect(hoisted.removeChannel).toHaveBeenCalledWith(first);
    expect(hoisted.channels).toHaveLength(2);
    expect(hoisted.channels[1].name).toBe("thread:c2");
    expect(hoisted.channels[1].subscriptions[0].config).toMatchObject({
      filter: "conversation_id=eq.c2",
    });
  });

  it("releases the channel on unmount", async () => {
    const { root } = await mount("c1");
    const channel = hoisted.channels[0];

    await act(async () => root.unmount());
    mounted = mounted.filter((entry) => entry !== root);

    expect(hoisted.removeChannel).toHaveBeenCalledWith(channel);
  });

  it("does not subscribe without an open conversation", async () => {
    await mount(null);
    expect(hoisted.channels).toHaveLength(0);
  });
});
