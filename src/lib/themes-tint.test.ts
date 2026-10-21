import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { THEME_IDS } from "@/lib/themes";

const css = readFileSync(join(process.cwd(), "src/app/globals.css"), "utf8");

const EXPECTED_HUE: Record<string, number> = {
  teal: 180,
  emerald: 162,
  cobalt: 254,
  violet: 293,
  amber: 65,
  rose: 16,
};

describe("style A tint hue per accent", () => {
  it.each(THEME_IDS)("theme %s defines --tint-h", (id) => {
    const block = css.match(new RegExp(`html\\[data-theme="${id}"\\] \\{[^}]*\\}`));
    expect(block, `block for ${id}`).not.toBeNull();
    const hue = block![0].match(/--tint-h:\s*(\d+);/);
    expect(hue, `--tint-h in ${id}`).not.toBeNull();
    expect(Number(hue![1])).toBe(EXPECTED_HUE[id]);
  });

  it("neutral and sidebar tokens follow --tint-h in both modes", () => {
    for (const mode of ["dark", "light"]) {
      const start = css.indexOf(`html[data-mode="${mode}"] {`);
      const block = css.slice(start, css.indexOf("\n}", start));
      for (const token of ["background", "card-2", "border", "sidebar", "sidebar-accent", "muted-foreground"]) {
        expect(block).toMatch(new RegExp(`--${token}: oklch\\([^)]*--tint-h`));
      }
    }
  });
});
