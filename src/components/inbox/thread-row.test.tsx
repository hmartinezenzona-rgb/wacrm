// @vitest-environment jsdom
// Slice 2: the thread row is memoized. An unrelated parent render must not
// re-render rows whose props did not change, and a changed message must
// re-render only its own row.
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "@/types";

const counts = vi.hoisted(() => ({ byId: {} as Record<string, number> }));

vi.mock("next-intl", () => ({ useTranslations: () => (key: string) => key }));
vi.mock("./message-bubble", () => ({
  MessageBubble: ({ message }: { message: Message }) => {
    counts.byId[message.id] = (counts.byId[message.id] ?? 0) + 1;
    return null;
  },
}));
vi.mock("./message-actions", () => ({
  MessageActions: ({ children }: { children?: React.ReactNode }) =>
    React.createElement(React.Fragment, null, children),
}));

import { ThreadRow } from "./thread-row";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const m1 = {
  id: "m1",
  conversation_id: "c1",
  sender_type: "customer",
  content_type: "text",
  content_text: "first",
  status: "delivered",
  created_at: "2026-01-01T10:00:00Z",
} as Message;

const m2 = {
  id: "m2",
  conversation_id: "c1",
  sender_type: "agent",
  content_type: "text",
  content_text: "second",
  status: "sent",
  created_at: "2026-01-01T10:01:00Z",
} as Message;

// Stable identities, exactly as the thread now hoists them.
const onReply = vi.fn();
const onReact = vi.fn();
const onTogglePill = vi.fn();
const onJump = vi.fn();

// One root per test: memoization only means anything across re-renders of the
// same mounted tree, not across remounts.
let root: ReturnType<typeof createRoot> | null = null;

function paint(rows: Message[]) {
  if (!root) {
    const node = document.createElement("div");
    document.body.appendChild(node);
    root = createRoot(node);
  }
  const mounted = root;
  return act(async () =>
    mounted.render(
      <>
        {rows.map((message) => (
          <ThreadRow
            key={message.id}
            message={message}
            contactDisplayName="Ana"
            currentUserId="u1"
            onReply={onReply}
            onReact={onReact}
            onTogglePill={onTogglePill}
            onJump={onJump}
          />
        ))}
      </>,
    ),
  );
}

beforeEach(() => {
  counts.byId = {};
  root = null;
});

describe("ThreadRow memoization", () => {
  it("equal props do not re-render the row", async () => {
    await paint([m1, m2]);
    expect(counts.byId).toEqual({ m1: 1, m2: 1 });

    // Same message objects and the same stable callbacks: both rows bail out.
    await paint([m1, m2]);
    expect(counts.byId).toEqual({ m1: 1, m2: 1 });
  });

  it("a changed message re-renders only that row", async () => {
    await paint([m1, m2]);
    expect(counts.byId).toEqual({ m1: 1, m2: 1 });

    const edited = { ...m2, content_text: "second (edited)" } as Message;
    await paint([m1, edited]);
    expect(counts.byId.m1).toBe(1);
    expect(counts.byId.m2).toBe(2);
  });
});
