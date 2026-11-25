// @vitest-environment jsdom
//
// 396 makes the "Revendedor" tag owner/admin-only in the database. This
// covers the panel side of that guard in the contact detail view:
//   - for an agent the reseller chip is visible but disabled and explains
//     why; every other chip stays editable;
//   - for an admin the chip is enabled and carries the bot-effect hint;
//   - a 42501 from the database (stale role in the client) is surfaced as
//     a readable Spanish message and never changes the chip state.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import es from "../../../messages/es.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const toastError = vi.hoisted(() => vi.fn());
vi.mock("sonner", () => ({ toast: { error: toastError, success: vi.fn() } }));

const auth = vi.hoisted(() => ({ accountId: "account-1", accountRole: "agent" as string | null }));
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => auth }));

const state = vi.hoisted(() => ({
  contact: {
    id: "contact-1",
    user_id: "user-1",
    account_id: "account-1",
    phone: "5219622896918",
    name: "Ana Perez",
    email: null,
    company: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
  tags: [
    { id: "tag-res", name: "Revendedor", color: "#ef4444" },
    { id: "tag-other", name: "Cliente", color: "#22c55e" },
  ],
  contactTags: [{ tag_id: "tag-other" }] as { tag_id: string }[],
  tagWriteError: null as null | { code?: string; message?: string; hint?: string },
}));

vi.mock("@/lib/supabase/client", () => {
  // One stable client: the component keeps `createClient()` in useCallback
  // dependencies, so a new object per call would loop the fetch effects.
  const client = {
    from: (table: string) => {
      const builder: Record<string, unknown> = {
        select: () => builder,
        eq: () => builder,
        order: () => builder,
        single: () => Promise.resolve({ data: state.contact, error: null }),
        insert: () => Promise.resolve({ error: state.tagWriteError }),
        delete: () => {
          const chain: Record<string, unknown> = {
            eq: () => chain,
            then: (resolve: (value: { error: unknown }) => unknown) =>
              resolve({ error: state.tagWriteError }),
          };
          return chain;
        },
        then: (resolve: (value: { data: unknown; error: null }) => unknown) =>
          resolve({ data: listResult(table), error: null }),
      };
      return builder;
    },
    auth: { getSession: () => Promise.resolve({ data: { session: null } }) },
  };
  return { createClient: () => client };
});

function listResult(table: string) {
  if (table === "tags") return state.tags;
  if (table === "contact_tags") return state.contactTags;
  return [];
}

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce(
        (acc: Record<string, unknown>, part) => acc?.[part] as Record<string, unknown>,
        es as unknown as Record<string, unknown>,
      );
    return (key: string, values?: Record<string, string | number>) => {
      const raw = key
        .split(".")
        .reduce((acc: unknown, part) => (acc as Record<string, unknown>)?.[part], node) as
        | string
        | undefined;
      if (raw === undefined) return key;
      return raw.replace(/\{(\w+)\}/g, (_, k) => String(values?.[k]));
    };
  },
}));

beforeEach(() => {
  auth.accountRole = "agent";
  state.tagWriteError = null;
  state.contactTags = [{ tag_id: "tag-other" }];
});

afterEach(() => {
  document.body.replaceChildren();
  toastError.mockClear();
});

async function render() {
  const { ContactDetailView } = await import("./contact-detail-view");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => {
    root.render(
      <ContactDetailView open onOpenChange={() => {}} contactId="contact-1" onUpdated={() => {}} />,
    );
  });
  await act(async () => {});
  return { root, node };
}

/** The tab order is details, tags, notes, custom. */
function openTagsTab() {
  const triggers = Array.from(document.querySelectorAll<HTMLElement>('[role="tab"]'));
  expect(triggers.length).toBeGreaterThanOrEqual(2);
  act(() => {
    triggers[1].dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

function chip(name: string): HTMLButtonElement {
  const found = Array.from(document.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === name,
  );
  if (!found) throw new Error(`chip ${name} not rendered`);
  return found as HTMLButtonElement;
}

describe("ContactDetailView reseller tag guard", () => {
  it("agent: the reseller chip is visible but disabled with the explanation, other chips stay editable", async () => {
    const { root } = await render();
    openTagsTab();

    const reseller = chip("Revendedor");
    expect(reseller.disabled).toBe(true);
    expect(reseller.getAttribute("title")).toBe(
      es.Contacts.detailView.tagsTab.resellerTagAdminOnly,
    );

    const other = chip("Cliente");
    expect(other.disabled).toBe(false);

    await act(async () => root.unmount());
  });

  it("admin: the reseller chip is enabled and shows the bot-effect hint", async () => {
    auth.accountRole = "admin";
    const { root } = await render();
    openTagsTab();

    const reseller = chip("Revendedor");
    expect(reseller.disabled).toBe(false);
    expect(reseller.getAttribute("title")).toBe(
      es.Contacts.detailView.tagsTab.resellerTagBotHint,
    );

    await act(async () => root.unmount());
  });

  it("surfaces a 42501 insert refusal as a readable Spanish message and keeps the chip state", async () => {
    auth.accountRole = "admin"; // stale client role: the database still refuses
    state.tagWriteError = {
      code: "42501",
      hint: "reseller_tag_admin_only",
      message: "only an owner or admin can add or remove the Revendedor tag",
    };

    const { root } = await render();
    openTagsTab();

    const reseller = chip("Revendedor");
    await act(async () => {
      reseller.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await act(async () => {});

    expect(toastError).toHaveBeenCalledWith(
      es.Contacts.detailView.tagsTab.resellerTagRefused,
    );
    expect(chip("Revendedor").className).not.toContain("ring-2");

    await act(async () => root.unmount());
  });

  it("surfaces a 42501 delete refusal and keeps the chip selected", async () => {
    auth.accountRole = "admin";
    state.contactTags = [{ tag_id: "tag-other" }, { tag_id: "tag-res" }];
    state.tagWriteError = {
      code: "42501",
      hint: "reseller_tag_admin_only",
      message: "only an owner or admin can add or remove the Revendedor tag",
    };

    const { root } = await render();
    openTagsTab();

    const reseller = chip("Revendedor");
    expect(reseller.className).toContain("ring-2");
    await act(async () => {
      reseller.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await act(async () => {});

    expect(toastError).toHaveBeenCalledWith(
      es.Contacts.detailView.tagsTab.resellerTagRefused,
    );
    expect(chip("Revendedor").className).toContain("ring-2");

    await act(async () => root.unmount());
  });
});
