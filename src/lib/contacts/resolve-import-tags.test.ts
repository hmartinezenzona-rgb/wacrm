import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";

import {
  assignImportedContactTags,
  resolveImportTagIds,
} from "./resolve-import-tags";

interface FakeTag {
  id: string;
  name: string;
}

function fakeSupabase(existing: FakeTag[]) {
  const insertCalls: FakeTag[][] = [];
  const upsertCalls: { contact_id: string; tag_id: string }[][] = [];

  let created = 0;
  const client = {
    from(table: string) {
      if (table === "tags") {
        return {
          select: () => ({
            eq: () => Promise.resolve({ data: existing, error: null }),
          }),
          insert: (rows: { name: string }[]) => {
            const inserted = rows.map((row) => {
              created += 1;
              return { id: `new-${created}`, name: row.name };
            });
            insertCalls.push(inserted);
            return {
              select: () => Promise.resolve({ data: inserted, error: null }),
            };
          },
        };
      }
      if (table === "contact_tags") {
        return {
          upsert: (rows: { contact_id: string; tag_id: string }[]) => {
            upsertCalls.push(rows);
            return Promise.resolve({ error: null });
          },
        };
      }
      throw new Error(`unexpected table ${table}`);
    },
  };

  return {
    supabase: client as unknown as SupabaseClient,
    insertCalls,
    upsertCalls,
  };
}

const baseParams = {
  accountId: "account-1",
  userId: "user-1",
  canCreateTags: true,
};

describe("resolveImportTagIds reseller gating", () => {
  it("skips an existing reseller tag for non-admins and reports it", async () => {
    const { supabase } = fakeSupabase([
      { id: "tag-res", name: "Revendedor" },
      { id: "tag-client", name: "Cliente" },
    ]);

    const result = await resolveImportTagIds(supabase, {
      ...baseParams,
      tagNames: ["Revendedor", "Cliente"],
      canAssignResellerTag: false,
    });

    expect(result.tagIdByKey.has("revendedor")).toBe(false);
    expect(result.tagIdByKey.get("cliente")).toBe("tag-client");
    expect(result.skippedNames).toContain("Revendedor");
  });

  it("does not create a missing reseller tag for non-admins", async () => {
    const { supabase, insertCalls } = fakeSupabase([
      { id: "tag-client", name: "Cliente" },
    ]);

    const result = await resolveImportTagIds(supabase, {
      ...baseParams,
      tagNames: ["Revendedor", "Cliente"],
      canAssignResellerTag: false,
    });

    expect(result.tagIdByKey.has("revendedor")).toBe(false);
    expect(result.skippedNames).toContain("Revendedor");
    expect(insertCalls.flat().map((tag) => tag.name)).not.toContain("Revendedor");
  });

  it("matches the reseller name case-insensitively when skipping", async () => {
    const { supabase } = fakeSupabase([
      { id: "tag-res", name: "Revendedor" },
    ]);

    const result = await resolveImportTagIds(supabase, {
      ...baseParams,
      tagNames: ["  REVENDEDOR  "],
      canAssignResellerTag: false,
    });

    expect(result.tagIdByKey.size).toBe(0);
    expect(result.skippedNames).toHaveLength(1);
  });

  it("assigns the reseller tag by default (admin path)", async () => {
    const { supabase } = fakeSupabase([
      { id: "tag-res", name: "Revendedor" },
    ]);

    const result = await resolveImportTagIds(supabase, {
      ...baseParams,
      tagNames: ["Revendedor"],
    });

    expect(result.tagIdByKey.get("revendedor")).toBe("tag-res");
    expect(result.skippedNames).toEqual([]);
  });

  it("creates the reseller tag for admins when it is missing", async () => {
    const { supabase, insertCalls } = fakeSupabase([]);

    const result = await resolveImportTagIds(supabase, {
      ...baseParams,
      tagNames: ["Revendedor"],
      canAssignResellerTag: true,
    });

    expect(result.tagIdByKey.has("revendedor")).toBe(true);
    expect(insertCalls.flat().map((tag) => tag.name)).toContain("Revendedor");
  });

  it("never emits a reseller pair when the map lacks it", async () => {
    const { supabase, upsertCalls } = fakeSupabase([]);

    const assigned = await assignImportedContactTags(
      supabase,
      [{ contactId: "contact-1", tagNames: ["Revendedor", "Cliente"] }],
      new Map([["cliente", "tag-client"]]),
    );

    expect(assigned).toBe(1);
    expect(upsertCalls.flat()).toEqual([
      { contact_id: "contact-1", tag_id: "tag-client" },
    ]);
  });
});
