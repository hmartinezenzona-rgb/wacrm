import { describe, expect, it } from "vitest";
import { parseUsdBalanceBody, parseUsdCardBody, parseUsdLotBody, parseUsdLotPatchBody } from "./payloads";

const CARD = "11111111-1111-1111-1111-111111111111";

describe("parseUsdCardBody", () => {
  it("create needs service and name", () => {
    expect(parseUsdCardBody({ name: "A" }, "create")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({ service: "CLASICA" }, "create")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({ service: "ZELLE", name: "A" }, "create")).toMatchObject({ ok: false });
  });
  it("create accepts a full card", () => {
    expect(parseUsdCardBody({ service: "TROPICAL", name: " T ", last4: "1234", priority: 2, monthlyLimitUsd: 3000, active: true }, "create")).toEqual({
      ok: true, value: { service: "TROPICAL", name: "T", last4: "1234", priority: 2, monthlyLimitUsd: 3000, active: true },
    });
  });
  it("update cannot change the service and needs a field", () => {
    expect(parseUsdCardBody({ service: "CLASICA" }, "update")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({}, "update")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({ active: false }, "update")).toEqual({ ok: true, value: { active: false } });
  });
  it("null last4 clears on update; bad values fail", () => {
    expect(parseUsdCardBody({ last4: null }, "update")).toEqual({ ok: true, value: { last4: "" } });
    expect(parseUsdCardBody({ service: "CLASICA", name: "A", last4: "12" }, "create")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({ service: "CLASICA", name: "A", monthlyLimitUsd: 0 }, "create")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({ service: "CLASICA", name: "A", priority: 1.5 }, "create")).toMatchObject({ ok: false });
    expect(parseUsdCardBody({ service: "CLASICA", name: "A", accountId: "x" }, "create")).toMatchObject({ ok: false });
    expect(parseUsdCardBody("x", "create")).toMatchObject({ ok: false });
  });
});

describe("parseUsdLotBody", () => {
  it("accepts a lot", () => {
    expect(parseUsdLotBody({ cardId: CARD, amountUsd: 500, usdtPaid: 476.19, note: " n ", loadedAt: "2026-11-02T10:00:00Z" })).toEqual({
      ok: true, value: { cardId: CARD, amountUsd: 500, usdtPaid: 476.19, note: "n", loadedAt: "2026-11-02T10:00:00.000Z" },
    });
  });
  it.each([
    ["no card", { amountUsd: 1, usdtPaid: 1 }],
    ["bad card", { cardId: "x", amountUsd: 1, usdtPaid: 1 }],
    ["amount zero", { cardId: CARD, amountUsd: 0, usdtPaid: 1 }],
    ["no usdtPaid", { cardId: CARD, amountUsd: 1 }],
    ["usdtPaid string", { cardId: CARD, amountUsd: 1, usdtPaid: "1" }],
    ["bad date", { cardId: CARD, amountUsd: 1, usdtPaid: 1, loadedAt: "nope" }],
    ["long note", { cardId: CARD, amountUsd: 1, usdtPaid: 1, note: "x".repeat(501) }],
    ["unknown key", { cardId: CARD, amountUsd: 1, usdtPaid: 1, rate: 1 }],
  ])("%s fails", (_l, body) => expect(parseUsdLotBody(body)).toMatchObject({ ok: false }));
});

describe("parseUsdLotPatchBody", () => {
  it("accepts partial fields; null note clears", () => {
    expect(parseUsdLotPatchBody({ usdtPaid: 400, note: null })).toEqual({ ok: true, value: { usdtPaid: 400, note: "" } });
  });
  it("rejects empty, cardId and bad numbers", () => {
    expect(parseUsdLotPatchBody({})).toMatchObject({ ok: false });
    expect(parseUsdLotPatchBody({ cardId: CARD, amountUsd: 1 })).toMatchObject({ ok: false });
    expect(parseUsdLotPatchBody({ amountUsd: -1 })).toMatchObject({ ok: false });
  });
});

describe("parseUsdBalanceBody", () => {
  it("accepts zero and a reason", () => {
    expect(parseUsdBalanceBody({ balanceUsd: 0, reason: " r " })).toEqual({ ok: true, value: { balanceUsd: 0, reason: "r" } });
  });
  it("rejects negatives, text and unknown keys", () => {
    expect(parseUsdBalanceBody({ balanceUsd: -1 })).toMatchObject({ ok: false });
    expect(parseUsdBalanceBody({ balanceUsd: "5" })).toMatchObject({ ok: false });
    expect(parseUsdBalanceBody({ balanceUsd: 5, balanceCup: 1 })).toMatchObject({ ok: false });
  });
});
