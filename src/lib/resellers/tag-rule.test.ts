import { describe, expect, it } from "vitest";

import {
  RESELLER_TAG_ADMIN_ONLY_HINT,
  isResellerTagName,
  isResellerTagRefusal,
} from "./tag-rule";

describe("isResellerTagName", () => {
  it.each(["Revendedor", "revendedor", "REVENDEDOR", "  revendedor  ", "\tRevendedor\n"])(
    "matches %j after trimming and ignoring case",
    (name) => {
      expect(isResellerTagName(name)).toBe(true);
    },
  );

  it.each(["Revendedores", "Revendedór", "Revendedor extra", "revendedora", "admin", ""])(
    "rejects %j (plural, accents, extra text, other tags, empty)",
    (name) => {
      expect(isResellerTagName(name)).toBe(false);
    },
  );

  it("rejects null, undefined and whitespace-only names", () => {
    expect(isResellerTagName(null)).toBe(false);
    expect(isResellerTagName(undefined)).toBe(false);
    expect(isResellerTagName("   ")).toBe(false);
  });
});

describe("isResellerTagRefusal", () => {
  it("recognises the database hint", () => {
    expect(
      isResellerTagRefusal({ code: "42501", hint: RESELLER_TAG_ADMIN_ONLY_HINT }),
    ).toBe(true);
  });

  it("recognises the guard message when the hint is missing", () => {
    expect(
      isResellerTagRefusal({
        code: "42501",
        message: "only an owner or admin can add or remove the Revendedor tag",
      }),
    ).toBe(true);
  });

  it("ignores unrelated errors", () => {
    expect(
      isResellerTagRefusal({
        code: "42501",
        message: "permission denied for table contact_tags",
      }),
    ).toBe(false);
    expect(isResellerTagRefusal({ code: "23505", message: "duplicate key" })).toBe(false);
    expect(isResellerTagRefusal(null)).toBe(false);
    expect(isResellerTagRefusal(undefined)).toBe(false);
  });
});
