// @vitest-environment jsdom
//
// 396 refuses an agent's edit of the "Revendedor" tag. The contact form
// used to delete EVERY tag of the contact and re-insert the selection; for
// an agent saving a reseller contact that DELETE is refused and the
// re-insert then trips UNIQUE(contact_id, tag_id), which the form reported
// as a duplicate phone. These tests pin the diff behaviour (only changed
// ids are written), the error surfacing, and the same chip gating the
// detail view uses.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import es from "../../../messages/es.json";
import type { Contact, ContactTag } from "@/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const toastError = vi.hoisted(() => vi.fn());
const toastSuccess = vi.hoisted(() => vi.fn());
vi.mock("sonner", () => ({ toast: { error: toastError, success: toastSuccess } }));

const auth = vi.hoisted(() => ({ accountId: "account-1", accountRole: "agent" as string | null }));
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => auth }));

const state = vi.hoisted(() => ({
  tags: [
    { id: "tag-res", name: "Revendedor", color: "#ef4444" },
    { id: "tag-client", name: "Cliente", color: "#22c55e" },
    { id: "tag-vip", name: "VIP", color: "#3b82f6" },
  ],
  ops: [] as { op: "insert" | "delete"; tagIds: string[] }[],
  tagWriteError: null as null | { message?: string; code?: string; hint?: string },
}));

vi.mock("@/lib/supabase/client", () => {
  const client = {
    from: (table: string) => {
      const builder: Record<string, unknown> = {
        select: () => builder,
        eq: () => builder,
        order: () => Promise.resolve({ data: table === "tags" ? state.tags : [], error: null }),
        single: () => Promise.resolve({ data: { id: "contact-1" }, error: null }),
        update: () => ({ eq: () => Promise.resolve({ error: null }) }),
        insert: (rows: unknown) => {
          const list = (Array.isArray(rows) ? rows : [rows]) as { tag_id?: string }[];
          if (table === "contact_tags") {
            state.ops.push({
              op: "insert",
              tagIds: list.map((row) => String(row.tag_id)),
            });
          }
          return Promise.resolve({ error: state.tagWriteError });
        },
        delete: () => {
          let eqCount = 0;
          const chain: Record<string, unknown> = {};
          chain.eq = (_column: string, value: unknown) => {
            eqCount += 1;
            if (table === "contact_tags" && eqCount === 2) {
              state.ops.push({ op: "delete", tagIds: [String(value)] });
            }
            return chain;
          };
          chain.then = (resolve: (value: { error: unknown }) => unknown) =>
            resolve({ error: state.tagWriteError });
          return chain;
        },
      };
      return builder;
    },
    auth: {
      getSession: () =>
        Promise.resolve({ data: { session: { user: { id: "user-1" } } } }),
    },
  };
  return { createClient: () => client };
});

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

const contact = {
  id: "contact-1",
  user_id: "user-1",
  account_id: "account-1",
  phone: "5219622896918",
  name: "Ana Perez",
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
} as Contact;

function tag(tagId: string): ContactTag {
  return { id: `ct-${tagId}`, contact_id: "contact-1", tag_id: tagId } as ContactTag;
}

beforeEach(() => {
  auth.accountRole = "agent";
  state.ops = [];
  state.tagWriteError = null;
});

afterEach(() => {
  document.body.replaceChildren();
  toastError.mockClear();
  toastSuccess.mockClear();
});

async function render(contactTags: ContactTag[], onSaved = vi.fn()) {
  const { ContactForm } = await import("./contact-form");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => {
    root.render(
      <ContactForm
        open
        onOpenChange={() => {}}
        contact={contact}
        contactTags={contactTags}
        onSaved={onSaved}
      />,
    );
  });
  await act(async () => {});
  return { root, onSaved };
}

function chip(name: string): HTMLButtonElement {
  const found = Array.from(document.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === name,
  );
  if (!found) throw new Error(`chip ${name} not rendered`);
  return found as HTMLButtonElement;
}

async function click(element: HTMLElement) {
  await act(async () => {
    element.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await act(async () => {});
}

async function submit() {
  const button = document.querySelector<HTMLButtonElement>('form button[type="submit"]');
  if (!button) throw new Error("submit button not rendered");
  await click(button);
}

describe("ContactForm tag diff sync", () => {
  it("agent saving a reseller contact removes only the changed tag", async () => {
    const { root } = await render([tag("tag-res"), tag("tag-client")]);

    await click(chip("Cliente")); // deselect the only editable change
    await submit();

    expect(state.ops).toEqual([{ op: "delete", tagIds: ["tag-client"] }]);
    // The unchanged reseller tag is neither deleted nor re-inserted.
    expect(state.ops.some((op) => op.tagIds.includes("tag-res"))).toBe(false);

    await act(async () => root.unmount());
  });

  it("inserts only the added tag without deleting the current ones", async () => {
    const { root } = await render([tag("tag-client")]);

    await click(chip("VIP"));
    await submit();

    expect(state.ops).toEqual([{ op: "insert", tagIds: ["tag-vip"] }]);

    await act(async () => root.unmount());
  });

  it("issues no tag statement when the selection did not change", async () => {
    const { root } = await render([tag("tag-res"), tag("tag-client")]);

    await submit();

    expect(state.ops).toEqual([]);

    await act(async () => root.unmount());
  });

  it("surfaces a tag write error and does not report the save as done", async () => {
    state.tagWriteError = { message: "boom" };
    const onSaved = vi.fn();
    const { root } = await render([tag("tag-client")], onSaved);

    await click(chip("VIP"));
    await submit();

    expect(toastError).toHaveBeenCalledWith("boom");
    expect(onSaved).not.toHaveBeenCalled();
    expect(toastSuccess).not.toHaveBeenCalled();

    await act(async () => root.unmount());
  });

  it("agent: the reseller chip is disabled with the explanation, other chips stay editable", async () => {
    const { root } = await render([tag("tag-client")]);

    const reseller = chip("Revendedor");
    expect(reseller.disabled).toBe(true);
    expect(reseller.getAttribute("title")).toBe(
      es.Contacts.form.resellerTagAdminOnly,
    );
    expect(chip("Cliente").disabled).toBe(false);

    await act(async () => root.unmount());
  });
});
