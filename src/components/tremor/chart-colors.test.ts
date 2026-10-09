import { describe, expect, it } from "vitest";
import { AvailableChartColors, chartColors, getColorClassName } from "./chart-colors";

describe("chart colours", () => {
  it("offers the money tones as named colours backed by the --money-* tokens", () => {
    expect(getColorClassName("money-in", "fill")).toBe("fill-money-in");
    expect(getColorClassName("money-in", "bg")).toBe("bg-money-in");
    expect(getColorClassName("money-profit", "fill")).toBe("fill-money-profit");
  });

  it("keeps the default palette of the dashboard charts untouched", () => {
    expect(AvailableChartColors).toEqual(["blue", "emerald", "violet", "amber", "gray", "cyan", "pink", "lime", "fuchsia"]);
    expect(Object.keys(chartColors)).toContain("money-in");
  });
});
