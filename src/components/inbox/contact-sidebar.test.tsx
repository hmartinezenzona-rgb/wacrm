// @vitest-environment jsdom
// Contact sidebar layout: the bot pause control sits right under the
// contact's phone (above tags), and the deals section is gone — including
// its `deals` query.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import type { Contact, Conversation } from "@/types";
// Imported statically, not with `await import()` inside the test body.
// This module pulls in date-fns, the lucide icon set and several UI
// components; loading and transforming that tree costs ~1.7s, and inside
// a test it is charged to that test's 5s budget. Under full-suite
// parallelism it crossed the limit and the FIRST test here timed out
// intermittently while the second (module already cached) ran in 15ms.
// vitest hoists `vi.mock` above imports, so the mocks below still apply.
import { ContactSidebar } from "./contact-sidebar";
import { contactAvatarDataUri } from "@/lib/avatars/contact-avatar";

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

async function render(c: Contact = contact) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ContactSidebar contact={c} conversation={conversation} />));
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
    const botIndex = text.indexOf(en.Inbox.sidebar.bot);
    const tagsIndex = text.indexOf(en.Inbox.sidebar.tags);
    expect(botIndex).toBeGreaterThan(-1);
    expect(tagsIndex).toBeGreaterThan(-1);
    expect(botIndex).toBeLessThan(tagsIndex);
    expect(text.indexOf(contact.phone)).toBeLessThan(botIndex);

    // The button became a Switch — the on/off state now lives in the
    // accessible name, not visible text (see the removed longform
    // "Pause bot"/"Resume bot" button this replaced).
    const toggle = node.querySelector('[role="switch"]');
    expect(toggle).not.toBeNull();
    expect(toggle?.getAttribute("aria-label")).toBe(en.Inbox.sidebar.pauseBot);
    await act(async () => root.unmount());
  });

  it("shows the generated illustration instead of the initial when there is no photo", async () => {
    const { node, root } = await render();

    const img = node.querySelector('img[alt=""]');
    expect(img?.getAttribute("src")).toMatch(/^data:image\/svg\+xml/);
    await act(async () => root.unmount());
  });

  it("passes the contact's avatar gender and number to the illustration", async () => {
    const { node, root } = await render({ ...contact, avatar_gender: "f", avatar_seq: 7 });

    const img = node.querySelector('img[alt=""]');
    expect(img?.getAttribute("src")).toBe(contactAvatarDataUri(contact.id, "f", 7));
    expect(img?.getAttribute("src")).not.toBe(contactAvatarDataUri(contact.id));
    await act(async () => root.unmount());
  });
});
