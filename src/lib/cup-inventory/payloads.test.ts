// Body validation shared by the inventory routes: strict shapes, finite numbers in range, nothing unknown.
import { describe, expect, it } from "vitest";
import { parseBalanceBody, parseCardBody, parseLotBody, parseLotPatchBody } from "./payloads";

describe("parseCardBody", () => {
  it("create: name is required; the rest is optional", () => {
    expect(parseCardBody({ name: " Tarjeta A " }, "create")).toEqual({ ok: true, value: { name: "Tarjeta A" } });
    expect(parseCardBody({}, "create").ok).toBe(false);
  });

  it("accepts last4, priority, dailyLimitCup, active", () => {
    expect(parseCardBody({ name: "A", last4: "1234", priority: 2, dailyLimitCup: 90000, active: false }, "create")).toEqual({
      ok: true,
      value: { name: "A", last4: "1234", priority: 2, dailyLimitCup: 90000, active: false },
    });
  });

  it("update: at least one field; last4 null clears it", () => {
    expect(parseCardBody({}, "update").ok).toBe(false);
    expect(parseCardBody({ last4: null }, "update")).toEqual({ ok: true, value: { last4: "" } });
    expect(parseCardBody({ active: false }, "update")).toEqual({ ok: true, value: { active: false } });
  });

  it.each([
    ["non-object", "x"],
    ["array", []],
    ["null", null],
    ["empty name", { name: "  " }],
    ["name too long", { name: "x".repeat(61) }],
    ["last4 short", { name: "A", last4: "123" }],
    ["last4 letters", { name: "A", last4: "12ab" }],
    ["last4 number", { name: "A", last4: 1234 }],
    ["priority fractional", { name: "A", priority: 1.5 }],
    ["priority negative", { name: "A", priority: -1 }],
    ["priority string", { name: "A", priority: "1" }],
    ["limit zero", { name: "A", dailyLimitCup: 0 }],
    ["limit NaN", { name: "A", dailyLimitCup: Number.NaN }],
    ["limit huge", { name: "A", dailyLimitCup: 1e12 }],
    ["active string", { name: "A", active: "yes" }],
    ["unknown key", { name: "A", accountId: "x" }],
  ])("rejects %s", (_label, body) => {
    expect(parseCardBody(body, "create").ok).toBe(false);
  });
});

describe("parseLotBody", () => {
  const base = { cardId: "11111111-1111-1111-1111-111111111111", amountCup: 500000, rateCupPerUsdt: 960 };

  it("accepts a lot with optional note and loadedAt", () => {
    expect(parseLotBody(base)).toEqual({ ok: true, value: base });
    expect(parseLotBody({ ...base, note: " compra ", loadedAt: "2026-10-14T12:00:00Z" })).toEqual({
      ok: true,
      value: { ...base, note: "compra", loadedAt: "2026-10-14T12:00:00.000Z" },
    });
  });

  it.each([
    ["no cardId", { amountCup: 1, rateCupPerUsdt: 1 }],
    ["cardId not a uuid", { ...base, cardId: "nope" }],
    ["amount zero", { ...base, amountCup: 0 }],
    ["amount string", { ...base, amountCup: "500000" }],
    ["amount Infinity", { ...base, amountCup: Number.POSITIVE_INFINITY }],
    ["rate zero", { ...base, rateCupPerUsdt: 0 }],
    ["rate beyond the column", { ...base, rateCupPerUsdt: 1e9 }],
    ["note not a string", { ...base, note: 5 }],
    ["note too long", { ...base, note: "x".repeat(501) }],
    ["loadedAt not a date", { ...base, loadedAt: "yesterday-ish" }],
    ["unknown key", { ...base, remainingCup: 1 }],
    ["null body", null],
  ])("rejects %s", (_label, body) => {
    expect(parseLotBody(body).ok).toBe(false);
  });
});

describe("parseLotPatchBody", () => {
  it("needs at least one of amountCup, rateCupPerUsdt, note", () => {
    expect(parseLotPatchBody({}).ok).toBe(false);
    expect(parseLotPatchBody({ amountCup: 100 })).toEqual({ ok: true, value: { amountCup: 100 } });
    expect(parseLotPatchBody({ note: null })).toEqual({ ok: true, value: { note: "" } });
    expect(parseLotPatchBody({ rateCupPerUsdt: 975, note: "x" })).toEqual({ ok: true, value: { rateCupPerUsdt: 975, note: "x" } });
  });

  it.each([
    ["amount negative", { amountCup: -1 }],
    ["rate zero", { rateCupPerUsdt: 0 }],
    ["cardId is not editable", { cardId: "11111111-1111-1111-1111-111111111111", amountCup: 1 }],
    ["note number", { note: 3 }],
  ])("rejects %s", (_label, body) => {
    expect(parseLotPatchBody(body).ok).toBe(false);
  });
});

describe("parseBalanceBody", () => {
  it("balanceCup is required; zero is valid; the reason is trimmed and optional", () => {
    expect(parseBalanceBody({ balanceCup: 222840 })).toEqual({ ok: true, value: { balanceCup: 222840 } });
    expect(parseBalanceBody({ balanceCup: 0 })).toEqual({ ok: true, value: { balanceCup: 0 } });
    expect(parseBalanceBody({ balanceCup: 10, reason: "  conteo real " })).toEqual({ ok: true, value: { balanceCup: 10, reason: "conteo real" } });
    expect(parseBalanceBody({ balanceCup: 10, reason: "   " })).toEqual({ ok: true, value: { balanceCup: 10 } });
    expect(parseBalanceBody({ balanceCup: 10, reason: null })).toEqual({ ok: true, value: { balanceCup: 10 } });
  });

  it.each([
    ["non-object", "x"],
    ["array", []],
    ["missing", {}],
    ["negative", { balanceCup: -1 }],
    ["text", { balanceCup: "10" }],
    ["NaN", { balanceCup: Number.NaN }],
    ["too big", { balanceCup: 1e12 }],
    ["reason not text", { balanceCup: 1, reason: 5 }],
    ["reason too long", { balanceCup: 1, reason: "x".repeat(501) }],
    ["unknown key", { balanceCup: 1, note: "x" }],
  ])("rejects %s", (_label, body) => {
    expect(parseBalanceBody(body).ok).toBe(false);
  });
});
