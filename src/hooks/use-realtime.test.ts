// @vitest-environment jsdom
//
// Slice 3 (ADR-5): the account-wide channel keeps listening to message INSERTs
// only (the chat sound, the conversation-list preview and unknown-conversation
// hydration depend on them) and to every `conversations` change. Per-conversation
// UPDATEs are the new thread channel's job (see use-thread-realtime.test.ts).

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

import { useRealtime } from "./use-realtime";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

interface Handlers {
  onMessageEvent: (event: unknown) => void;
  onConversationEvent: (event: unknown) => void;
}

function Probe({ enabled, handlers }: { enabled: boolean; handlers: Handlers }) {
  useRealtime({
    channelName: "inbox-realtime",
    onMessageEvent: handlers.onMessageEvent,
    onConversationEvent: handlers.onConversationEvent,
    enabled,
  });
  return null;
}

let mounted: Array<{ unmount: () => void }> = [];

beforeEach(() => {
  hoisted.channels.length = 0;
  hoisted.removeChannel.mockClear();
});

afterEach(async () => {
  await act(async () => (mounted.splice(0).forEach((root) => root.unmount())));
  document.body.replaceChildren();
});

async function mount(enabled = true) {
  const handlers: Handlers = {
    onMessageEvent: vi.fn(),
    onConversationEvent: vi.fn(),
  };
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(React.createElement(Probe, { enabled, handlers })));
  mounted.push(root);
  return { handlers, root };
}

describe("useRealtime", () => {
  it("subscribes messages to INSERT only and conversations to every change", async () => {
    await mount();

    expect(hoisted.channels).toHaveLength(1);
    const channel = hoisted.channels[0];
    expect(channel.name).toBe("inbox-realtime");
    expect(channel.subscriptions).toHaveLength(2);

    const [messages, conversations] = channel.subscriptions;
    expect(messages.event).toBe("postgres_changes");
    expect(messages.config).toEqual({
      event: "INSERT",
      schema: "public",
      table: "messages",
    });
    expect(messages.config).not.toHaveProperty("filter");

    expect(conversations.event).toBe("postgres_changes");
    expect(conversations.config).toEqual({
      event: "*",
      schema: "public",
      table: "conversations",
    });
  });

  it("forwards message and conversation payloads to their handlers", async () => {
    const { handlers } = await mount();
    const channel = hoisted.channels[0];
    const [messages, conversations] = channel.subscriptions;

    await act(async () => {
      messages.handler({ eventType: "INSERT", new: { id: "m1" }, old: {} });
      conversations.handler({ eventType: "UPDATE", new: { id: "c1" }, old: {} });
    });

    expect(handlers.onMessageEvent).toHaveBeenCalledWith({
      eventType: "INSERT",
      new: { id: "m1" },
      old: {},
    });
    expect(handlers.onConversationEvent).toHaveBeenCalledWith({
      eventType: "UPDATE",
      new: { id: "c1" },
      old: {},
    });
  });

  it("releases the channel on unmount", async () => {
    const { root } = await mount();
    const channel = hoisted.channels[0];

    await act(async () => root.unmount());
    mounted = mounted.filter((r) => r !== root);

    expect(hoisted.removeChannel).toHaveBeenCalledWith(channel);
  });

  it("does not subscribe while disabled", async () => {
    await mount(false);
    expect(hoisted.channels).toHaveLength(0);
  });
});
