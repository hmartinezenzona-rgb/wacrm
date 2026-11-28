import { describe, expect, it } from "vitest";
import { RATE_FIELDS, RATE_GROUPS, ungroupedRates } from "./rate-groups";

describe("the Tasas actuales groups", () => {
  it("places every rate of RATE_FIELDS in exactly one group", () => {
    const placed = RATE_GROUPS.flatMap((group) => group.rates.map((rate) => rate.key));
    expect(new Set(placed).size).toBe(placed.length);
    expect([...placed].sort()).toEqual(RATE_FIELDS.map((field) => field.key).sort());
    expect(ungroupedRates(RATE_GROUPS)).toEqual([]);
  });

  it("keeps the four groups of the approved mockup, in order", () => {
    expect(RATE_GROUPS.map((group) => group.title)).toEqual([
      "USDT",
      "Zelle · GYD por dólar",
      "Recargas y saldo · costo",
      "CUP, efectivo y México",
    ]);
  });

  it("gives every rate a unit or none, never an empty label", () => {
    for (const rate of RATE_GROUPS.flatMap((group) => group.rates)) expect(rate.label.length).toBeGreaterThan(0);
  });

  it("reports a rate that no group lists, so a new RATE_FIELDS entry is never lost", () => {
    const without = RATE_GROUPS.map((group) => ({ ...group, rates: group.rates.filter((rate) => rate.key !== "efectivo_usd_gyd") }));
    expect(ungroupedRates(without).map((field) => field.key)).toEqual(["efectivo_usd_gyd"]);
  });
});
