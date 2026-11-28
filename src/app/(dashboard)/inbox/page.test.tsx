// @vitest-environment jsdom
//
// Slice 3 review correction: the inbox page had no test at all. The realtime
// narrowing (messages INSERT only, UPDATEs moved to the filtered thread
// channel) lives in the page's `handleMessageEvent`, which is reachable only
// through the real `useRealtime` subscription boundary. These cases drive that
// exact path — the real page, the real hook, the real sound gate — and pin the
// four INSERT consumers the narrowing could silently break:
//   1. an INSERT for the open conversation appends to the thread;
//   2. an INSERT for another known conversation patches exactly one list row
//      and preserves the identity of the others;
//   3. an INSERT for an unknown conversation hydrates from the DB;
//   4. a customer INSERT in a non-active conversation rings the sound gate.
//
// The handler is never re-implemented here: the test captures the channel the
// hook registered and invokes its INSERT payload.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

interface Subscription {
  event: string;
  config: Record<string, unknown>;
  handler: (payload: unknown) => void;
}

interface FakeChannel {
  name: string;
  subscriptions: Subscription[];
}

const hoisted = vi.hoisted(() => ({
  play: vi.fn(),
  stop: vi.fn(),
  listProps: null as any,
  threadProps: null as any,
  channels: [] as FakeChannel[],
  removeChannel: vi.fn(),
  fromCalls: [] as Array<{ table: string; eqs: Array<[string, string]> }>,
}));

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

// The children are not under test here. Recording their latest props is how
// the test observes the state the page computed from the realtime event.
vi.mock("@/components/inbox/conversation-list", () => ({
  ConversationList: (props: unknown) => {
    hoisted.listProps = props;
    return null;
  },
}));
vi.mock("@/components/inbox/message-thread", () => ({
  MessageThread: (props: unknown) => {
    hoisted.threadProps = props;
    return null;
  },
}));
vi.mock("@/components/inbox/contact-sidebar", () => ({
  ContactSidebar: () => null,
}));
vi.mock("@/components/ui/sheet", () => ({
  Sheet: () => null,
  SheetContent: () => null,
  SheetTitle: () => null,
}));

// Only the audio element is replaced. The real `createChatSoundGate` still runs
// inside the page, so "play was called" means the gate allowed the ring.
vi.mock("@/hooks/use-chat-message-sound", () => ({
  useChatMessageSound: () => ({ play: hoisted.play, stop: hoisted.stop }),
}));

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: null } }),
    },
    from: (table: string) => {
      const call = { table, eqs: [] as Array<[string, string]> };
      hoisted.fromCalls.push(call);
      const chain = {
        select: () => chain,
        eq: (column: string, value: string) => {
          call.eqs.push([column, value]);
          return chain;
        },
        maybeSingle: async () => ({ data: null, error: null }),
        single: async () => ({ data: null, error: null }),
      };
      return chain;
    },
    channel: (name: string) => {
      const subscriptions: Subscription[] = [];
      const channel = {
        name,
        subscriptions,
        on: (event: string, config: Record<string, unknown>, handler: (payload: unknown) => void) => {
          subscriptions.push({ event, config, handler });
          return channel;
        },
        subscribe: (callback?: (status: string) => void) => {
          callback?.("SUBSCRIBED");
          return channel;
        },
      };
      hoisted.channels.push(channel);
      return channel;
    },
    removeChannel: hoisted.removeChannel,
  }),
}));

import InboxPage from "./page";

const conversation = (id: string, over: Record<string, unknown> = {}) =>
  ({
    id,
    unread_count: 0,
    last_message_text: "",
    last_message_at: "2026-11-27T09:00:00.000Z",
    status: "open",
    contact: { id: `contact-${id}`, name: `Contact ${id}` },
    ...over,
  }) as any;

const message = (
  id: string,
  conversationId: string,
  over: Record<string, unknown> = {},
) =>
  ({
    id,
    conversation_id: conversationId,
    content_text: `body ${id}`,
    created_at: "2026-11-27T10:00:00.000Z",
    sender_type: "customer",
    ...over,
  }) as any;

let mounted: Array<{ unmount: () => void }> = [];

beforeEach(() => {
  hoisted.channels.length = 0;
  hoisted.fromCalls.length = 0;
  hoisted.listProps = null;
  hoisted.threadProps = null;
  hoisted.play.mockClear();
  hoisted.stop.mockClear();
  hoisted.removeChannel.mockClear();
});

afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((root) => root.unmount()));
  document.body.replaceChildren();
});

async function mount() {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(React.createElement(InboxPage)));
  mounted.push(root);
  return node;
}

/** The INSERT subscription the real hook registered on the account channel. */
function inboxInsertHandler(): (payload: unknown) => void {
  const channel = hoisted.channels.find((entry) => entry.name === "inbox-realtime");
  if (!channel) throw new Error("inbox-realtime channel was not subscribed");
  const subscription = channel.subscriptions.find(
    (entry) => entry.config.table === "messages",
  );
  if (!subscription) throw new Error("messages subscription was not registered");
  return subscription.handler;
}

async function dispatchInsert(row: Record<string, unknown>) {
  await act(async () => {
    inboxInsertHandler()({ eventType: "INSERT", new: row, old: {} });
    // Let any async hydration started by the handler settle.
    await Promise.resolve();
  });
}

async function seedConversations(rows: unknown[]) {
  await act(async () => {
    hoisted.listProps.onConversationsLoaded(rows);
  });
}

async function selectConversation(row: unknown) {
  await act(async () => {
    hoisted.listProps.onSelect(row);
  });
}

describe("InboxPage realtime INSERT wiring", () => {
  it("appends an INSERT for the open conversation to the thread", async () => {
    await mount();
    const open = conversation("a");
    await seedConversations([open]);
    await selectConversation(open);

    const first = message("m0", "a", { sender_type: "agent" });
    await act(async () => {
      hoisted.threadProps.onMessagesLoaded([first]);
    });

    await dispatchInsert(
      message("m1", "a", { sender_type: "agent", content_text: "hello" }),
    );

    expect(hoisted.threadProps.messages.map((row: any) => row.id)).toEqual([
      "m0",
      "m1",
    ]);
    // The gate stays silent for the conversation the agent is reading.
    expect(hoisted.play).not.toHaveBeenCalled();
  });

  it("patches exactly one list row for an INSERT of another conversation", async () => {
    await mount();
    const a = conversation("a", { unread_count: 0, last_message_text: "a-old" });
    const b = conversation("b", { unread_count: 1, last_message_text: "b-old" });
    const c = conversation("c", { unread_count: 2, last_message_text: "c-old" });
    await seedConversations([a, b, c]);
    const before = hoisted.listProps.conversations as any[];

    await dispatchInsert(
      message("m1", "b", {
        sender_type: "agent",
        content_text: "b-new",
        created_at: "2026-11-27T11:00:00.000Z",
      }),
    );

    const after = hoisted.listProps.conversations as any[];
    expect(after).toHaveLength(3);

    const changed = after.filter((row, index) => row !== before[index]);
    expect(changed).toHaveLength(1);
    expect(changed[0].id).toBe("b");
    expect(changed[0].last_message_text).toBe("b-new");
    expect(changed[0].unread_count).toBe(2);

    // Identity of the unaffected rows is preserved, not rebuilt.
    expect(after.find((row) => row.id === "a")).toBe(a);
    expect(after.find((row) => row.id === "c")).toBe(c);
  });

  it("hydrates a conversation it does not know when its INSERT arrives", async () => {
    await mount();
    await seedConversations([conversation("a")]);
    hoisted.fromCalls.length = 0;

    await dispatchInsert(
      message("m1", "unknown-1", { sender_type: "agent" }),
    );

    const hydration = hoisted.fromCalls.find(
      (call) =>
        call.table === "conversations" &&
        call.eqs.some(([column, value]) => column === "id" && value === "unknown-1"),
    );
    expect(hydration).toBeDefined();
    // The hydrate response is empty here, so the list is only touched later by
    // the conversation event; the important part is that it was requested.
    expect(
      (hoisted.listProps.conversations as any[]).map((row) => row.id),
    ).toEqual(["a"]);
  });

  it("rings the sound gate for a customer INSERT in a non-active conversation", async () => {
    await mount();
    const open = conversation("a");
    const other = conversation("b");
    await seedConversations([open, other]);
    await selectConversation(open);

    await dispatchInsert(message("m1", "b", { sender_type: "customer" }));
    expect(hoisted.play).toHaveBeenCalledTimes(1);

    // A customer message in the open conversation stays silent.
    await dispatchInsert(message("m2", "a", { sender_type: "customer" }));
    expect(hoisted.play).toHaveBeenCalledTimes(1);
  });
});
