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
let contactTags: unknown[] = [];

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => {
      queriedTables.push(table);
      const builder = {
        select: () => builder,
        eq: () => builder,
        order: () => builder,
        then: (resolve: (value: { data: unknown[] }) => unknown) =>
          resolve({ data: table === "contact_tags" ? contactTags : [] }),
      };
      return builder;
    },
  }),
}));

vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ accountId: "account-1", profile: { beta_features: [] } }),
}));

vi.mock("next-intl", () => ({
  useLocale: () => "en",
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
  contactTags = [];
  vi.unstubAllGlobals();
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

async function render(c: Contact = contact, conv: Conversation = conversation) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ContactSidebar contact={c} conversation={conv} />));
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

  describe("bot pause: automatic vs manual", () => {
    afterEach(() => vi.unstubAllGlobals());

    // jsdom has no PointerEvent and the Switch dispatches one on click.
    if (typeof window.PointerEvent === "undefined") {
      (window as unknown as { PointerEvent: typeof MouseEvent }).PointerEvent = MouseEvent;
    }

    function stubFetch() {
      const calls: { url: string; body: unknown }[] = [];
      vi.stubGlobal(
        "fetch",
        vi.fn(async (url: string, init?: RequestInit) => {
          calls.push({ url, body: init?.body ? JSON.parse(String(init.body)) : null });
          return new Response(JSON.stringify({ success: true }), { status: 200 });
        }),
      );
      return calls;
    }

    it("an automatic pause (a person replied) leaves the switch off and explains it comes back alone", async () => {
      const { node, root } = await render(contact, {
        id: "conv-1",
        ai_autoreply_disabled: true,
        ai_handoff_reason: "agent_replied",
      } as Conversation);
      const toggle = node.querySelector('[role="switch"]');
      expect(toggle?.getAttribute("aria-checked")).toBe("false");
      expect(toggle?.getAttribute("aria-label")).toBe(en.Inbox.sidebar.pauseBot);
      expect(node.textContent).toContain(en.Inbox.sidebar.botAutoPausedHint);
      await act(async () => root.unmount());
    });

    it("touching the switch during an automatic pause makes it manual instead of resuming the bot", async () => {
      const calls = stubFetch();
      const { node, root } = await render(contact, {
        id: "conv-1",
        ai_autoreply_disabled: true,
        ai_handoff_reason: "agent_replied",
      } as Conversation);
      const toggle = node.querySelector('[role="switch"]') as HTMLElement;
      await act(async () => toggle.click());
      expect(calls).toHaveLength(1);
      expect(calls[0].body).toEqual({ paused: true });
      expect(toggle.getAttribute("aria-checked")).toBe("true");
      await act(async () => root.unmount());
    });

    it("a manual pause shows the switch on and touching it resumes the bot", async () => {
      const calls = stubFetch();
      const { node, root } = await render(contact, {
        id: "conv-1",
        ai_autoreply_disabled: true,
        ai_handoff_reason: null,
      } as Conversation);
      const toggle = node.querySelector('[role="switch"]') as HTMLElement;
      expect(toggle.getAttribute("aria-checked")).toBe("true");
      expect(node.textContent).toContain(en.Inbox.sidebar.botPausedHint);
      await act(async () => toggle.click());
      expect(calls[0].body).toEqual({ paused: false });
      await act(async () => root.unmount());
    });
  });

  describe("reseller block", () => {
    const resellerTag = {
      id: "ct-reseller",
      tag_id: "tag-reseller",
      tags: { id: "tag-reseller", name: "Revendedor", color: "#22c55e" },
    };

    const resellerDetail = {
      reseller: {
        contactId: "contact-1",
        name: "Test Contact",
        phone: "5219622896918",
        isReseller: true,
        pendingClaims: 0,
        current: {
          periodStart: "2026-11-21T12:00:00Z",
          depositsGyd: 12000,
          depositsCount: 2,
          operationsGyd: 0,
          historicalOperationsGyd: 0,
          operationsCount: 0,
          operationsMissingAmount: 0,
          adjustmentsGyd: 0,
          adjustmentsCount: 0,
          countedGyd: 12000,
          totalGyd: 12000,
          adjustments: [],
        },
        periods: [],
      },
    };

    async function settle() {
      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });
    }

    it("renders the block for a tagged contact and fetches only that contact's total", async () => {
      contactTags = [resellerTag];
      const fetchMock = vi.fn(async () =>
        new Response(JSON.stringify(resellerDetail), { status: 200 }),
      );
      vi.stubGlobal("fetch", fetchMock);

      const { node, root } = await render();
      await settle();

      expect(fetchMock).toHaveBeenCalledWith("/api/revendedores/contact-1", { cache: "no-store" });
      expect(node.textContent).toContain(en.Resellers.sidebar.title);
      expect(node.textContent).toContain("12,000 GYD");
      await act(async () => root.unmount());
    });

    it("does not request or render the block for an untagged contact", async () => {
      contactTags = [];
      const fetchMock = vi.fn();
      vi.stubGlobal("fetch", fetchMock);

      const { node, root } = await render();
      await settle();

      expect(fetchMock).not.toHaveBeenCalled();
      expect(node.textContent).not.toContain(en.Resellers.sidebar.title);
      await act(async () => root.unmount());
    });
  });
});
