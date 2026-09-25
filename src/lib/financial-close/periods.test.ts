import { describe, expect, it } from "vitest";
import { guyanaToday, periodRange, shiftPeriod, validateRange, MAX_RANGE_DAYS } from "./periods";

describe("guyanaToday", () => {
  it("returns the Guyana calendar day, not the UTC one (UTC-4, no DST)", () => {
    // 02:00 UTC on the 10th is still 22:00 on the 9th in Guyana.
    expect(guyanaToday(new Date("2026-08-10T02:00:00Z"))).toBe("2026-08-09");
    // 04:00 UTC is exactly midnight in Guyana: the new day has started.
    expect(guyanaToday(new Date("2026-08-10T04:00:00Z"))).toBe("2026-08-10");
  });
});

describe("periodRange", () => {
  it("day: the same date on both ends", () => {
    expect(periodRange("day", "2026-08-05")).toEqual({ desde: "2026-08-05", hasta: "2026-08-05" });
  });

  it("week: Monday to Sunday containing the date", () => {
    // 2026-08-05 is a Wednesday.
    expect(periodRange("week", "2026-08-05")).toEqual({ desde: "2026-08-03", hasta: "2026-08-09" });
    // A Sunday belongs to the week that started the Monday before.
    expect(periodRange("week", "2026-08-09")).toEqual({ desde: "2026-08-03", hasta: "2026-08-09" });
    // A Monday starts its own week.
    expect(periodRange("week", "2026-08-10")).toEqual({ desde: "2026-08-10", hasta: "2026-08-16" });
  });

  it("week: crosses a month boundary", () => {
    expect(periodRange("week", "2026-09-30")).toEqual({ desde: "2026-09-28", hasta: "2026-10-04" });
  });

  it("month: first to last day, leap February included", () => {
    expect(periodRange("month", "2026-09-17")).toEqual({ desde: "2026-09-01", hasta: "2026-09-30" });
    expect(periodRange("month", "2028-02-10")).toEqual({ desde: "2028-02-01", hasta: "2028-02-29" });
    expect(periodRange("month", "2026-12-31")).toEqual({ desde: "2026-12-01", hasta: "2026-12-31" });
  });
});

describe("shiftPeriod", () => {
  it("moves a day, a week or a month backwards and forwards", () => {
    expect(shiftPeriod("day", { desde: "2026-09-01", hasta: "2026-09-01" }, -1)).toEqual({
      desde: "2026-08-31",
      hasta: "2026-08-31",
    });
    expect(shiftPeriod("week", { desde: "2026-09-28", hasta: "2026-10-04" }, 1)).toEqual({
      desde: "2026-10-05",
      hasta: "2026-10-11",
    });
    expect(shiftPeriod("month", { desde: "2026-01-01", hasta: "2026-01-31" }, -1)).toEqual({
      desde: "2025-12-01",
      hasta: "2025-12-31",
    });
    expect(shiftPeriod("month", { desde: "2026-01-01", hasta: "2026-01-31" }, 1)).toEqual({
      desde: "2026-02-01",
      hasta: "2026-02-28",
    });
  });

  it("range: moves by its own length", () => {
    expect(shiftPeriod("range", { desde: "2026-09-01", hasta: "2026-09-10" }, 1)).toEqual({
      desde: "2026-09-11",
      hasta: "2026-09-20",
    });
  });
});

describe("validateRange", () => {
  it("accepts a valid range up to the RPC's cap", () => {
    expect(validateRange({ desde: "2026-09-01", hasta: "2026-09-01" })).toBeNull();
    expect(MAX_RANGE_DAYS).toBe(366);
    expect(validateRange({ desde: "2025-08-03", hasta: "2026-08-03" })).toBeNull();
  });

  it("rejects missing, malformed, reversed and too-long ranges", () => {
    expect(validateRange({ desde: "", hasta: "2026-09-01" })).toBe("missing");
    expect(validateRange({ desde: "2026-13-01", hasta: "2026-09-01" })).toBe("invalid");
    expect(validateRange({ desde: "2026-09-02", hasta: "2026-09-01" })).toBe("reversed");
    expect(validateRange({ desde: "2025-08-01", hasta: "2026-08-03" })).toBe("too_long");
  });
});
