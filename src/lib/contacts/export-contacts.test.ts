import { describe, expect, it } from "vitest";
import {
  buildVCard,
  defaultPrefix,
  exportFileName,
} from "./export-contacts";

describe("buildVCard", () => {
  it("builds a vCard 3.0 with CRLF, prefixed FN/N and CELL phone", () => {
    const { vcf, exported, skipped } = buildVCard(
      [{ name: "Juan", phone: "5491155550000", email: "j@x.com" }],
      { prefix: "Nuevos" },
    );
    expect(vcf).toBe(
      [
        "BEGIN:VCARD",
        "VERSION:3.0",
        "FN:Nuevos - Juan",
        "N:;Nuevos - Juan;;;",
        "TEL;TYPE=CELL:+5491155550000",
        "EMAIL:j@x.com",
        "END:VCARD",
        "",
      ].join("\r\n"),
    );
    expect(exported).toBe(1);
    expect(skipped).toBe(0);
  });

  it("uses only the name when the prefix is empty/blank", () => {
    const { vcf } = buildVCard([{ name: "Ana", phone: "123456789" }], {
      prefix: "   ",
    });
    expect(vcf).toContain("FN:Ana\r\n");
    expect(vcf).not.toContain("EMAIL");
  });

  it("falls back to the formatted number when there is no name", () => {
    const { vcf } = buildVCard([{ name: null, phone: "5491100001111" }], {
      prefix: "Nuevos",
    });
    expect(vcf).toContain("FN:Nuevos - +5491100001111\r\n");
    const bare = buildVCard([{ name: " ", phone: "5491100001111" }], {
      prefix: "",
    });
    expect(bare.vcf).toContain("FN:+5491100001111\r\n");
  });

  it("strips non-digits from phones and skips contacts without digits", () => {
    const { vcf, exported, skipped } = buildVCard(
      [
        { name: "A", phone: "+54 9 11-5555-0000" },
        { name: "B", phone: "" },
        { name: "C", phone: "abc" },
        { name: "D", phone: null },
      ],
      { prefix: "" },
    );
    expect(vcf).toContain("TEL;TYPE=CELL:+5491155550000");
    expect(exported).toBe(1);
    expect(skipped).toBe(3);
    expect(vcf.match(/BEGIN:VCARD/g)).toHaveLength(1);
  });

  it("escapes backslash, comma, semicolon and newlines", () => {
    const { vcf } = buildVCard(
      [{ name: "A\\B, C; D\nE\r\nF", phone: "1234567" }],
      { prefix: "" },
    );
    expect(vcf).toContain("FN:A\\\\B\\, C\; D\\nE\\nF\r\n");
  });

  it("folds lines longer than 75 octets without splitting characters", () => {
    const name = "ñ".repeat(60); // 120 octets
    const { vcf } = buildVCard([{ name, phone: "1234567" }], { prefix: "" });
    const lines = vcf.split("\r\n");
    for (const line of lines) {
      expect(Buffer.byteLength(line, "utf8")).toBeLessThanOrEqual(75);
    }
    // Unfolding restores the original content.
    const unfolded = vcf.replace(/\r\n /g, "");
    expect(unfolded).toContain(`FN:${name}\r\n`);
  });

  it("returns an empty string when nothing is exportable", () => {
    const r = buildVCard([{ name: "x", phone: "" }], { prefix: "" });
    expect(r.vcf).toBe("");
    expect(r.exported).toBe(0);
    expect(r.skipped).toBe(1);
  });
});

describe("exportFileName", () => {
  it("includes the prefix and keeps accents", () => {
    expect(exportFileName("Nuevos")).toBe("contactos-Nuevos.vcf");
    expect(exportFileName("  Año Nuevo ")).toBe("contactos-Año Nuevo.vcf");
  });
  it("removes filesystem-unsafe characters", () => {
    expect(exportFileName('a/b\\c:d*e?f"g<h>i|j')).toBe("contactos-abcdefghij.vcf");
  });
  it("falls back when empty", () => {
    expect(exportFileName("")).toBe("contactos.vcf");
    expect(exportFileName(" /: ")).toBe("contactos.vcf");
  });
});

describe("defaultPrefix", () => {
  it("joins tag names with a space or returns empty", () => {
    expect(defaultPrefix(["Nuevos", "VIP"])).toBe("Nuevos VIP");
    expect(defaultPrefix([])).toBe("");
  });
});
