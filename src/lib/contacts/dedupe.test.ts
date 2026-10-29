import { describe, expect, it } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  dedupeByPhone,
  findExistingContact,
  isExactMatch,
  isUniqueViolation,
  normalizeKey,
} from "./dedupe";

describe("normalizeKey", () => {
  it("strips every non-digit", () => {
    expect(normalizeKey("+1 (555) 123-4567")).toBe("15551234567");
    expect(normalizeKey("15551234567")).toBe("15551234567");
  });

  it("collapses different formats of the same number to one key", () => {
    expect(normalizeKey("+44 7911 123456")).toBe(normalizeKey("447911123456"));
  });
});

describe("isExactMatch", () => {
  it("treats different formatting of the same digits as exact", () => {
    expect(isExactMatch({ id: "1", phone: "+1 555-123-4567" }, "15551234567")).toBe(
      true,
    );
  });

  it("is false for a trunk-variant (fuzzy) match", () => {
    // last-8 match but not the same full number
    expect(isExactMatch({ id: "1", phone: "37063949836" }, "370063949836")).toBe(
      false,
    );
  });
});

describe("isUniqueViolation", () => {
  it("detects Postgres 23505", () => {
    expect(isUniqueViolation({ code: "23505" })).toBe(true);
  });
  it("is false for other errors / non-objects", () => {
    expect(isUniqueViolation({ code: "23502" })).toBe(false);
    expect(isUniqueViolation(null)).toBe(false);
    expect(isUniqueViolation("boom")).toBe(false);
  });
});

describe("dedupeByPhone", () => {
  it("keeps the first occurrence and counts in-file duplicates", () => {
    const { unique, duplicates } = dedupeByPhone([
      { phone: "+1 555-1111", name: "A" },
      { phone: "15551111", name: "B" }, // same digits as #1
      { phone: "+1 555-2222", name: "C" },
    ]);
    expect(unique.map((r) => r.name)).toEqual(["A", "C"]);
    expect(duplicates).toBe(1);
  });

  it("drops rows with no digits", () => {
    const { unique, duplicates } = dedupeByPhone([
      { phone: "   " },
      { phone: "+1 555-3333" },
    ]);
    expect(unique).toHaveLength(1);
    expect(duplicates).toBe(1);
  });
});

describe("findExistingContact", () => {
  // Minimal SupabaseClient stub: resolves the .from().select().eq().like()
  // chain to a fixed candidate set.
  function stubDb(rows: Array<{ id: string; phone: string }>): SupabaseClient {
    const builder = {
      select: () => builder,
      eq: () => builder,
      like: () => Promise.resolve({ data: rows, error: null }),
    };
    return { from: () => builder } as unknown as SupabaseClient;
  }

  it("returns a trunk-variant match via phonesMatch", async () => {
    const db = stubDb([{ id: "c1", phone: "37063949836" }]);
    const hit = await findExistingContact(db, "acct", "+370 063 949 836");
    expect(hit?.id).toBe("c1");
  });

  it("returns null when no candidate matches", async () => {
    const db = stubDb([{ id: "c1", phone: "15559999999" }]);
    const hit = await findExistingContact(db, "acct", "+1 555-123-4567");
    expect(hit).toBeNull();
  });

  it("returns null for an empty phone without querying", async () => {
    const db = stubDb([{ id: "c1", phone: "15551234567" }]);
    expect(await findExistingContact(db, "acct", "   ")).toBeNull();
  });
});

describe("findExistingContact prefilter (formatted stored phones)", () => {
  // Fake that applies the SQL LIKE to the column it is asked about, the way
  // PostgREST would. `phone_normalized` mirrors the generated column of
  // migration 022 (digits-only); `phone` is the raw stored text.
  function likeDb(stored: string[]): SupabaseClient {
    const rows = stored.map((phone, i) => ({
      id: `c${i}`,
      phone,
      phone_normalized: phone.replace(/\D/g, ""),
    }));
    const builder = {
      select: () => builder,
      eq: () => builder,
      like: (column: string, pattern: string) => {
        const suffix = pattern.replace(/^%/, "");
        const hits = rows.filter((r) =>
          String((r as Record<string, string>)[column]).endsWith(suffix),
        );
        return Promise.resolve({ data: hits, error: null });
      },
    };
    return { from: () => builder } as unknown as SupabaseClient;
  }

  it.each([
    "+1 (555) 010-1234",
    "1 555 010 1234",
    "1.555.010.1234",
    "1-555-010-1234",
    "15550101234",
  ])("finds stored %s for an incoming digits-only phone", async (stored) => {
    const hit = await findExistingContact(likeDb([stored]), "acct", "15550101234");
    expect(hit?.phone).toBe(stored);
  });

  it("finds a digits-only stored phone for a formatted incoming phone", async () => {
    const hit = await findExistingContact(
      likeDb(["15550101234"]),
      "acct",
      "+1 (555) 010-1234",
    );
    expect(hit?.id).toBe("c0");
  });

  it("still returns null for a different number", async () => {
    const hit = await findExistingContact(
      likeDb(["+1 (620) 430-9999"]),
      "acct",
      "15550101234",
    );
    expect(hit).toBeNull();
  });
});
