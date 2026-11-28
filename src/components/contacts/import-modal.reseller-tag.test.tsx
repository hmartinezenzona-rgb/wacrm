// @vitest-environment jsdom
//
// 396: a non-admin import must not try to assign the "Revendedor" tag. The
// database would refuse the link and, with the import's 100-row batches,
// one refusal would fail every tag assignment in the batch. The modal
// passes canManageResellers(role) down to the resolver and reports the
// skipped reseller tag separately.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import es from "../../../messages/es.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const toast = vi.hoisted(() => ({
  info: vi.fn(),
  success: vi.fn(),
  warning: vi.fn(),
  error: vi.fn(),
}));
vi.mock("sonner", () => ({ toast }));

const auth = vi.hoisted(() => ({ accountId: "account-1", canEditSettings: false }));
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => auth }));

const resolver = vi.hoisted(() => ({ calls: [] as Record<string, unknown>[] }));
vi.mock("@/lib/contacts/resolve-import-tags", () => ({
  resolveImportTagIds: (_client: unknown, params: Record<string, unknown>) => {
    resolver.calls.push(params);
    const canAssign = params.canAssignResellerTag !== false;
    return Promise.resolve({
      tagIdByKey: canAssign ? new Map([["revendedor", "tag-res"]]) : new Map(),
      skippedNames: canAssign ? [] : ["Revendedor"],
    });
  },
  assignImportedContactTags: () => Promise.resolve(0),
}));

vi.mock("@/lib/contacts/parse-contact-csv", () => ({
  parseContactCsv: () => ({
    rows: [{ phone: "5219622896918", name: "Ana", tagNames: ["Revendedor"] }],
    hasTagsColumn: true,
    hasCompanyColumn: false,
  }),
}));

vi.mock("@/lib/supabase/client", () => {
  const client = {
    from: (table: string) => {
      if (table === "contacts") {
        const builder: Record<string, unknown> = {
          select: () => builder,
          eq: () => Promise.resolve({ data: [], error: null }),
          insert: () => ({
            select: () =>
              Promise.resolve({ data: [{ id: "contact-1" }], error: null }),
          }),
        };
        return builder;
      }
      return {
        select: () => ({ eq: () => Promise.resolve({ data: [], error: null }) }),
      };
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
    const translate = (key: string) => {
      const raw = key
        .split(".")
        .reduce((acc: unknown, part) => (acc as Record<string, unknown>)?.[part], node) as
        | string
        | undefined;
      return raw ?? key;
    };
    return Object.assign(translate, {
      markup: (key: string) => translate(key),
      rich: (key: string) => translate(key),
    });
  },
}));

beforeEach(() => {
  auth.canEditSettings = false;
  resolver.calls = [];
});

afterEach(() => {
  document.body.replaceChildren();
  Object.values(toast).forEach((fn) => fn.mockClear());
});

async function render(canEditSettings: boolean) {
  auth.canEditSettings = canEditSettings;
  const { ImportModal } = await import("./import-modal");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => {
    root.render(<ImportModal open onOpenChange={() => {}} onImported={() => {}} />);
  });
  return { root };
}

async function chooseFile() {
  const input = document.querySelector<HTMLInputElement>('input[type="file"]');
  if (!input) throw new Error("file input not rendered");
  const fakeFile = { name: "contacts.csv", text: async () => "phone,tags\n5219622896918,Revendedor" };
  Object.defineProperty(input, "files", { value: [fakeFile], configurable: true });
  await act(async () => {
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await act(async () => {});
}

async function clickImport() {
  const button = Array.from(document.querySelectorAll("button")).find((candidate) =>
    candidate.textContent?.includes("Importar"),
  );
  if (!button) throw new Error("import button not rendered");
  await act(async () => {
    button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await act(async () => {});
}

describe("ImportModal reseller tag gating", () => {
  it("non-admin: resolves tags with canAssignResellerTag=false and reports the skipped tag", async () => {
    const { root } = await render(false);
    await chooseFile();
    await clickImport();

    expect(resolver.calls[0]).toMatchObject({ canAssignResellerTag: false });
    expect(toast.info).toHaveBeenCalledWith(
      es.Contacts.importModal.toastResellerTagSkipped,
    );

    await act(async () => root.unmount());
  });

  it("admin: resolves tags with canAssignResellerTag=true", async () => {
    const { root } = await render(true);
    await chooseFile();
    await clickImport();

    expect(resolver.calls[0]).toMatchObject({ canAssignResellerTag: true });
    expect(toast.info).not.toHaveBeenCalledWith(
      es.Contacts.importModal.toastResellerTagSkipped,
    );

    await act(async () => root.unmount());
  });
});
