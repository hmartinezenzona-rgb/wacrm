// Body validation for the reseller totals routes on top of the 397 RPCs.
// Strict: known keys only, finite numbers, trimmed optional reasons.

import { describe, expect, it } from "vitest";

import { parseAdjustBody, parseResetAllBody, parseResetBody } from "./payloads";

describe("parseResetBody", () => {
  it("accepts an empty object as no reason and no expected total", () => {
    expect(parseResetBody({})).toEqual({
      ok: true,
      value: { reason: null, expectedTotalGyd: null },
    });
  });

  it("trims the reason and treats a blank reason as absent", () => {
    expect(parseResetBody({ reason: "  cierre de mes  " })).toEqual({
      ok: true,
      value: { reason: "cierre de mes", expectedTotalGyd: null },
    });
    expect(parseResetBody({ reason: "   " })).toEqual({
      ok: true,
      value: { reason: null, expectedTotalGyd: null },
    });
    expect(parseResetBody({ reason: null })).toEqual({
      ok: true,
      value: { reason: null, expectedTotalGyd: null },
    });
  });

  it("accepts zero and negative expected totals", () => {
    expect(parseResetBody({ expectedTotalGyd: 0 })).toEqual({
      ok: true,
      value: { reason: null, expectedTotalGyd: 0 },
    });
    expect(parseResetBody({ expectedTotalGyd: -2500 })).toEqual({
      ok: true,
      value: { reason: null, expectedTotalGyd: -2500 },
    });
  });

  it.each([
    ["a reason longer than 500 characters", { reason: "x".repeat(501) }],
    ["a non-string reason", { reason: 42 }],
    ["a non-finite expected total", { expectedTotalGyd: Number.POSITIVE_INFINITY }],
    ["a string expected total", { expectedTotalGyd: "100" }],
    ["a non-object body", "nope"],
    ["an array body", []],
    ["a null body", null],
    ["an unknown field", { expectedTotal: 10 }],
  ])("rejects %s", (_label, body) => {
    expect(parseResetBody(body).ok).toBe(false);
  });

  it("accepts a reason of exactly 500 characters", () => {
    const reason = "x".repeat(500);
    expect(parseResetBody({ reason })).toEqual({
      ok: true,
      value: { reason, expectedTotalGyd: null },
    });
  });
});

describe("parseResetAllBody", () => {
  it("accepts an empty object as no reason and no expected grand total", () => {
    expect(parseResetAllBody({})).toEqual({
      ok: true,
      value: { reason: null, expectedGrandTotalGyd: null },
    });
  });

  it("trims the reason and keeps an explicit expected grand total", () => {
    expect(parseResetAllBody({ reason: " cierre global ", expectedGrandTotalGyd: 7500 })).toEqual({
      ok: true,
      value: { reason: "cierre global", expectedGrandTotalGyd: 7500 },
    });
  });

  it.each([
    ["a reason longer than 500 characters", { reason: "x".repeat(501) }],
    ["a non-finite expected grand total", { expectedGrandTotalGyd: Number.NaN }],
    ["a non-object body", 7],
    ["an unknown field", { expectedTotalGyd: 10 }],
  ])("rejects %s", (_label, body) => {
    expect(parseResetAllBody(body).ok).toBe(false);
  });
});

describe("parseAdjustBody", () => {
  it("accepts a positive amount with no reason", () => {
    expect(parseAdjustBody({ amountGyd: 1500 })).toEqual({
      ok: true,
      value: { amountGyd: 1500, reason: null },
    });
  });

  it("accepts a negative amount and a trimmed reason", () => {
    expect(parseAdjustBody({ amountGyd: -300, reason: "  corrección  " })).toEqual({
      ok: true,
      value: { amountGyd: -300, reason: "corrección" },
    });
  });

  it("accepts a fractional amount", () => {
    expect(parseAdjustBody({ amountGyd: 0.5 })).toEqual({
      ok: true,
      value: { amountGyd: 0.5, reason: null },
    });
  });

  it.each([
    ["a missing amount", {}],
    ["a zero amount", { amountGyd: 0 }],
    ["a null amount", { amountGyd: null }],
    ["a non-finite amount", { amountGyd: Number.POSITIVE_INFINITY }],
    ["a string amount", { amountGyd: "100" }],
    ["an amount at the 1e12 bound", { amountGyd: 1e12 }],
    ["a reason longer than 500 characters", { amountGyd: 1, reason: "x".repeat(501) }],
    ["a non-object body", "nope"],
    ["an array body", []],
    ["an unknown field", { amountGyd: 1, motivo: "x" }],
  ])("rejects %s", (_label, body) => {
    expect(parseAdjustBody(body).ok).toBe(false);
  });
});
