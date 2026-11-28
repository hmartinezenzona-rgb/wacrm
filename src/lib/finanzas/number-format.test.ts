import { describe, expect, it } from "vitest";
import { num, pctText } from "./number-format";

describe("the panel's number format (comma thousands, dot decimals)", () => {
  it("groups with commas and drops decimals by default", () => {
    expect(num(35609)).toBe("35,609");
    expect(num(1157712.4)).toBe("1,157,712");
    expect(num(-4200)).toBe("-4,200");
  });

  it("writes decimals with a dot", () => {
    expect(num(239.5, 1)).toBe("239.5");
    expect(num(4.6, 2)).toBe("4.6");
  });

  it("writes a percentage with one decimal at most and a space before the sign", () => {
    expect(pctText(10.4)).toBe("10.4 %");
    expect(pctText(10)).toBe("10 %");
  });
});
