// @vitest-environment jsdom
// Slice: panel-26 (readiness). A conversation row fires the operations
// panel's prefetch on hover AND on focus — the inbox is "use client"
// (page.tsx) with no server render to piggyback on, so the single
// `/api/remittance-operations` round trip can only start earlier, not
// go faster. Keyboard users arrow through this list and never hover, so
// both onMouseEnter and onFocus are required, not just one.
//
// Selection/ordering/filtering are out of scope here — this file only
// covers the new prefetch wiring, and asserts selection behaviour is
// unchanged as a guard against the wiring breaking it.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import type { Conversation, Contact } from "@/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => node[key] as string;
  },
}));

// The list also fetches its own conversations/tags on mount — irrelevant
// to prefetch-on-hover, which is exercised through the `conversations`
// prop instead (as a real parent would hold that state). Resolves both
// tables to empty so the mount effects settle without error.
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: () => {
      const builder = {
        select: () => builder,
        eq: () => builder,
        is: () => builder,
        order: () => builder,
        then: (resolve: (value: { data: unknown[]; error: null }) => unknown) =>
          resolve({ data: [], error: null }),
      };
      return builder;
    },
  }),
}));

vi.mock("sonner", () => ({ toast: Object.assign(vi.fn(), { success: vi.fn(), error: vi.fn() }) }));

// ScrollArea/DropdownMenu wrap @base-ui/react primitives that lean on
// ResizeObserver/anchor-positioning — unavailable in jsdom and irrelevant
// to this file's assertions. Passthrough stand-ins keep the row markup
// (and its onMouseEnter/onFocus handlers) intact.
vi.mock("@/components/ui/scroll-area", () => ({
  ScrollArea: ({ children, className }: { children?: React.ReactNode; className?: string }) => (
    <div className={className}>{children}</div>
  ),
}));
vi.mock("@/components/ui/dropdown-menu", () => ({
  DropdownMenu: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  DropdownMenuTrigger: ({ children, ...props }: React.ComponentProps<"button">) => (
    <button {...props}>{children}</button>
  ),
  DropdownMenuContent: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  DropdownMenuItem: ({ children, ...props }: React.ComponentProps<"div">) => <div {...props}>{children}</div>,
  DropdownMenuCheckboxItem: ({ children, ...props }: React.ComponentProps<"div">) => (
    <div {...props}>{children}</div>
  ),
}));

const prefetchConversationOperations = vi.fn();
vi.mock("@/lib/remittance-operations/panel-prefetch", () => ({
  prefetchConversationOperations: (...args: unknown[]) => prefetchConversationOperations(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  prefetchConversationOperations.mockClear();
});

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function contact(overrides: Partial<Contact> = {}): Contact {
  return {
    id: "contact-1",
    user_id: "user-1",
    account_id: "account-1",
    phone: "5219622896918",
    name: "Ada Lovelace",
    created_at: "2026-09-14T00:00:00Z",
    updated_at: "2026-09-14T00:00:00Z",
    ...overrides,
  };
}

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: "conv-1",
    user_id: "user-1",
    contact_id: "contact-1",
    status: "open",
    unread_count: 0,
    created_at: "2026-09-14T00:00:00Z",
    updated_at: "2026-09-14T00:00:00Z",
    contact: contact(),
    ...overrides,
  };
}

async function renderList(conversations: Conversation[]) {
  const { ConversationList } = await import("./conversation-list");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onSelect = vi.fn();
  const onConversationsLoaded = vi.fn();
  await act(async () =>
    root.render(
      <ConversationList
        activeConversationId={null}
        onSelect={onSelect}
        conversations={conversations}
        onConversationsLoaded={onConversationsLoaded}
      />,
    ),
  );
  await flush();
  return { node, root, onSelect };
}

function rowFor(node: Element, name: string): HTMLElement {
  const row = Array.from(node.querySelectorAll('[role="button"]')).find((el) =>
    el.textContent?.includes(name),
  );
  if (!row) throw new Error(`row for "${name}" not found`);
  return row as HTMLElement;
}

describe("ConversationList — prefetch on hover/focus", () => {
  it("prefetches operations for a row's conversation on mouseenter", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(
        new MouseEvent("mouseover", { bubbles: true, cancelable: true, relatedTarget: document.body }),
      );
    });

    expect(prefetchConversationOperations).toHaveBeenCalledWith("conv-1");
    await act(async () => root.unmount());
  });

  it("prefetches operations for a row's conversation on focus (keyboard users never hover)", async () => {
    const convs = [conversation({ id: "conv-2", contact: contact({ name: "Grace Hopper" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Grace Hopper");
    await act(async () => {
      row.focus();
    });

    expect(prefetchConversationOperations).toHaveBeenCalledWith("conv-2");
    await act(async () => root.unmount());
  });

  it("does not prefetch a row that was never hovered or focused", async () => {
    const convs = [
      conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) }),
      conversation({ id: "conv-2", contact: contact({ name: "Grace Hopper" }) }),
    ];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(
        new MouseEvent("mouseover", { bubbles: true, cancelable: true, relatedTarget: document.body }),
      );
    });

    expect(prefetchConversationOperations).toHaveBeenCalledWith("conv-1");
    expect(prefetchConversationOperations).not.toHaveBeenCalledWith("conv-2");
    await act(async () => root.unmount());
  });

  it("still calls onSelect with the full conversation on click (selection unchanged)", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root, onSelect } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onSelect).toHaveBeenCalledWith(convs[0]);
    await act(async () => root.unmount());
  });
});
