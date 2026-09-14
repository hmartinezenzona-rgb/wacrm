// @vitest-environment jsdom
// Contact sidebar layout: the bot pause control sits right under the
// contact's phone (above tags), and the deals section is gone — including
// its `deals` query.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import type { Contact, Conversation } from "@/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const queriedTables: string[] = [];

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => {
      queriedTables.push(table);
      const builder = {
        select: () => builder,
        eq: () => builder,
        order: () => builder,
        then: (resolve: (value: { data: unknown[] }) => unknown) => resolve({ data: [] }),
      };
      return builder;
    },
  }),
}));

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ accountId: "account-1", profile: { beta_features: [] } }),
}));

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => node[key] as string;
  },
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

vi.mock("@/components/inbox/operations/operations-panel-container", () => ({
  OperationsPanelContainer: () => null,
}));

afterEach(() => {
  document.body.replaceChildren();
  queriedTables.length = 0;
});

const contact = {
  id: "contact-1",
  user_id: "user-1",
  account_id: "account-1",
  phone: "5219622896918",
  name: "Test Contact",
  created_at: "2026-09-14T00:00:00Z",
  updated_at: "2026-09-14T00:00:00Z",
} as Contact;

const conversation = { id: "conv-1", ai_autoreply_disabled: false } as Conversation;

async function render() {
  const { ContactSidebar } = await import("./contact-sidebar");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ContactSidebar contact={contact} conversation={conversation} />));
  return { node, root };
}

describe("ContactSidebar", () => {
  it("does not render the deals section nor query deals", async () => {
    const { node, root } = await render();

    expect(node.textContent).not.toContain(en.Inbox.sidebar.deals);
    expect(node.textContent).not.toContain(en.Inbox.sidebar.noDeals);
    expect(queriedTables).not.toContain("deals");
    await act(async () => root.unmount());
  });

  it("renders the bot pause control above the tags section", async () => {
    const { node, root } = await render();

    const text = node.textContent ?? "";
    const botIndex = text.indexOf(en.Inbox.sidebar.pauseBot);
    const tagsIndex = text.indexOf(en.Inbox.sidebar.tags);
    expect(botIndex).toBeGreaterThan(-1);
    expect(tagsIndex).toBeGreaterThan(-1);
    expect(botIndex).toBeLessThan(tagsIndex);
    expect(text.indexOf(contact.phone)).toBeLessThan(botIndex);
    await act(async () => root.unmount());
  });
});
