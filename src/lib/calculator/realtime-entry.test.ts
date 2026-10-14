// B4.2 — "the calculator updates in real time when a remesa completes, with
// no page refresh." Pure-function coverage for the raw
// `remittance_calculator_entries` row -> `ChatCalculatorEntry` mapping and
// the `chatEntries` fold, kept separate from the Supabase channel plumbing
// (`src/hooks/use-calculator-entries-realtime.ts`) so this is testable
// without mocking a realtime client.

import { describe, expect, it } from "vitest";
import {
  applyCalculatorEntryRealtimeEvent,
  mapRealtimeCalculatorEntry,
  type CalculatorEntryRealtimeRow,
  type ChatCalculatorEntry,
} from "./realtime-entry";

function row(overrides: Partial<CalculatorEntryRealtimeRow> = {}): CalculatorEntryRealtimeRow {
  return {
    id: "entry-1",
    operation_id: "op-1",
    status: "completed",
    service: "ZELLE",
    customer_name: "Raúl",
    amount: "100",
    amount_currency: "USD",
    entry_date: "2026-09-29",
    facturado_gyd: "26000",
    invertido_gyd: "24000",
    retorno_gyd: "2000",
    missing_inputs: [],
    source: "completed_operation",
    completed_at: null,
    ...overrides,
  };
}

describe("mapRealtimeCalculatorEntry", () => {
  it("maps a completed chat-fed row, coercing numeric-string columns to numbers", () => {
    expect(mapRealtimeCalculatorEntry(row())).toEqual<ChatCalculatorEntry>({
      id: "entry-1",
      operationId: "op-1", source: "completed_operation",
      status: "completed",
      service: "ZELLE",
      customerName: "Raúl",
      amount: 100,
      amountCurrency: "USD",
      entryDate: "2026-09-29",
      facturadoGyd: 26000,
      invertidoGyd: 24000,
      retornoGyd: 2000,
      missingRates: [],
      cupGlobalRate: null, cupRate: null, usdtBuyGyd: null, usdtSellGyd: null, costGyd: null, basisGyd: null, saleGyd: null,
    });
  });

  it("carries the rate snapshot of the row (numeric strings coerced, absent columns null)", () => {
    const mapped = mapRealtimeCalculatorEntry(
      row({ service: "CUP", cup_global_rate: "3", cup_rate: "960", usdt_buy_gyd: 205, usdt_sell_gyd: "215", cost_gyd: null, basis_gyd: "106000" }),
    );
    expect(mapped).toMatchObject({
      cupGlobalRate: 3, cupRate: 960, usdtBuyGyd: 205, usdtSellGyd: 215, costGyd: null, basisGyd: 106000, saleGyd: null,
    });
  });

  it("maps a verified_pending row, keeping null financial fields null", () => {
    const mapped = mapRealtimeCalculatorEntry(
      row({
        status: "verified_pending",
        facturado_gyd: null,
        invertido_gyd: null,
        retorno_gyd: null,
        missing_inputs: ["usdtSellCup"],
      }),
    );
    expect(mapped).toEqual<ChatCalculatorEntry>({
      id: "entry-1",
      operationId: "op-1", source: "completed_operation",
      status: "verified_pending",
      service: "ZELLE",
      customerName: "Raúl",
      amount: 100,
      amountCurrency: "USD",
      entryDate: "2026-09-29",
      facturadoGyd: null,
      invertidoGyd: null,
      retornoGyd: null,
      missingRates: ["usdtSellCup"],
      cupGlobalRate: null, cupRate: null, usdtBuyGyd: null, usdtSellGyd: null, costGyd: null, basisGyd: null, saleGyd: null,
    });
  });

  it("maps a manual entry (migration 228): no operation, marked manual", () => {
    expect(mapRealtimeCalculatorEntry(row({ id: "m1", operation_id: null, source: "manual", service: "DIRECTO", amount_currency: "GYD", amount: 4000 }))).toMatchObject({
      id: "m1", operationId: null, source: "manual", status: "completed", service: "DIRECTO", amount: 4000, amountCurrency: "GYD",
    });
  });

  it("returns null for a row that is neither a chat-fed nor a manual entry", () => {
    expect(mapRealtimeCalculatorEntry(row({ source: "something_else" }))).toBeNull();
  });

  it("returns null for a voided row, mirroring the GET route's status<>'void' filter", () => {
    expect(mapRealtimeCalculatorEntry(row({ status: "void" }))).toBeNull();
  });
});

describe("applyCalculatorEntryRealtimeEvent", () => {
  it("INSERT: prepends a newly-qualifying entry", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "old", operationId: "op-old", source: "completed_operation", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "2026-09-28", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ id: "entry-new" }), null);
    expect(next.map((e) => e.id)).toEqual(["entry-new", "old"]);
  });

  it("INSERT of a voided row is a no-op", () => {
    const existing: ChatCalculatorEntry[] = [];
    const next = applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ status: "void" }), null);
    expect(next).toEqual([]);
  });

  it("INSERT of a manual entry joins the list at its date (the list is newest day first)", () => {
    const base = { operationId: "op", source: "completed_operation" as const, status: "completed" as const, service: "CUP", customerName: "X", amount: 1, amountCurrency: "CUP", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] };
    const existing: ChatCalculatorEntry[] = [
      { ...base, id: "today", entryDate: "2026-10-07" },
      { ...base, id: "monday", entryDate: "2026-10-05" },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ id: "tue", operation_id: null, source: "manual", entry_date: "2026-10-06", created_at: "2026-10-07T20:00:00Z" }), null);
    expect(next.map((e) => e.id)).toEqual(["today", "tue", "monday"]);
    // a newer day goes first, a same-day entry goes before the ones already there (newest first)
    expect(applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ id: "later", entry_date: "2026-10-08" }), null).map((e) => e.id)).toEqual(["later", "today", "monday"]);
    expect(applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ id: "same", entry_date: "2026-10-07" }), null).map((e) => e.id)).toEqual(["same", "today", "monday"]);
  });

  it("a manual entry deleted (UPDATE to void) leaves the list", () => {
    const manual = mapRealtimeCalculatorEntry(row({ id: "m", operation_id: null, source: "manual" }))!;
    expect(applyCalculatorEntryRealtimeEvent([manual], "UPDATE", row({ id: "m", operation_id: null, source: "manual", status: "void" }), { id: "m" })).toEqual([]);
  });

  it("a corrected manual entry updates in place", () => {
    const manual = mapRealtimeCalculatorEntry(row({ id: "m", operation_id: null, source: "manual" }))!;
    const next = applyCalculatorEntryRealtimeEvent([manual], "UPDATE", row({ id: "m", operation_id: null, source: "manual", facturado_gyd: "30000", retorno_gyd: "6000" }), { id: "m" });
    expect(next[0]).toMatchObject({ id: "m", source: "manual", facturadoGyd: 30000, retornoGyd: 6000 });
  });

  it("UPDATE: replaces an existing entry in place, keeping array position", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", source: "completed_operation", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
      { id: "b", operationId: "op-b", source: "completed_operation", status: "verified_pending", service: "ZELLE", customerName: "B", amount: 100, amountCurrency: "USD", entryDate: "d", facturadoGyd: null, invertidoGyd: null, retornoGyd: null, missingRates: ["usdtSellGyd"] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(
      existing,
      "UPDATE",
      row({ id: "b", operation_id: "op-b", status: "completed", missing_inputs: [] }),
      { id: "b" },
    );
    expect(next.map((e) => e.id)).toEqual(["a", "b"]);
    expect(next[1]).toMatchObject({ id: "b", status: "completed", facturadoGyd: 26000 });
  });

  it("UPDATE to void removes the entry (the operation was cancelled/voided after being fed)", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", source: "completed_operation", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "UPDATE", row({ id: "a", status: "void" }), { id: "a" });
    expect(next).toEqual([]);
  });

  it("DELETE removes the entry by the old row's id", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", source: "completed_operation", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "DELETE", null, { id: "a" });
    expect(next).toEqual([]);
  });

  it("DELETE with no old id is a no-op", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", source: "completed_operation", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    expect(applyCalculatorEntryRealtimeEvent(existing, "DELETE", null, null)).toEqual(existing);
  });
});

describe("applyCalculatorEntryRealtimeEvent with the weekly cut", () => {
  const CUT = "2026-10-03T12:00:00.000Z";
  const shown: ChatCalculatorEntry = {
    id: "pending-1", operationId: "op-p", source: "completed_operation", status: "verified_pending", service: "CUP", customerName: "P", amount: 1,
    amountCurrency: "CUP", entryDate: "2026-09-29", facturadoGyd: null, invertidoGyd: null, retornoGyd: null, missingRates: ["usdtSellCup"],
  };

  it("ignores a completed entry older than the cut that the page does not show (it was archived)", () => {
    const next = applyCalculatorEntryRealtimeEvent([], "UPDATE", row({ id: "old", completed_at: "2026-10-01T10:00:00Z" }), { id: "old" }, CUT);
    expect(next).toEqual([]);
  });

  it("shows a completed entry completed after the cut", () => {
    const next = applyCalculatorEntryRealtimeEvent([], "INSERT", row({ id: "new", completed_at: "2026-10-04T10:00:00Z" }), null, CUT);
    expect(next.map((e) => e.id)).toEqual(["new"]);
  });

  it("keeps updating an entry the page already shows, however old it is (a pending line resolved after the cut)", () => {
    const next = applyCalculatorEntryRealtimeEvent([shown], "UPDATE", row({ id: "pending-1", operation_id: "op-p", completed_at: "2026-09-29T10:00:00Z" }), { id: "pending-1" }, CUT);
    expect(next).toHaveLength(1);
    expect(next[0]).toMatchObject({ id: "pending-1", status: "completed", facturadoGyd: 26000 });
  });

  it("shows a pending entry whatever its age (it is never archived)", () => {
    const next = applyCalculatorEntryRealtimeEvent([], "INSERT", row({ id: "p2", status: "verified_pending", facturado_gyd: null, invertido_gyd: null, retorno_gyd: null, completed_at: null }), null, CUT);
    expect(next.map((e) => e.id)).toEqual(["p2"]);
  });

  // A manual entry is dated on the day typed, so its completed_at (midday of that day) can be older than the cut even when it
  // was registered after it: for manual rows the moment of registration (created_at) decides.
  it("a manual entry registered after the cut shows even when its day is older than the cut", () => {
    const next = applyCalculatorEntryRealtimeEvent([], "INSERT", row({ id: "m", operation_id: null, source: "manual", entry_date: "2026-10-01", completed_at: "2026-10-01T16:00:00Z", created_at: "2026-10-04T10:00:00Z" }), null, CUT);
    expect(next.map((e) => e.id)).toEqual(["m"]);
  });

  it("a manual entry registered before the cut was archived with that week and does not come back", () => {
    const next = applyCalculatorEntryRealtimeEvent([], "UPDATE", row({ id: "m", operation_id: null, source: "manual", entry_date: "2026-10-04", completed_at: "2026-10-04T16:00:00Z", created_at: "2026-10-02T10:00:00Z" }), { id: "m" }, CUT);
    expect(next).toEqual([]);
  });

  it("without a cut every completed entry shows, as before", () => {
    const next = applyCalculatorEntryRealtimeEvent([], "INSERT", row({ id: "x", completed_at: "2020-01-01T00:00:00Z" }), null, null);
    expect(next.map((e) => e.id)).toEqual(["x"]);
  });

  it("a deleted entry arrives as an UPDATE to void and leaves the list", () => {
    const completed: ChatCalculatorEntry = { ...shown, id: "c", status: "completed", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] };
    const next = applyCalculatorEntryRealtimeEvent([completed], "UPDATE", row({ id: "c", status: "void" }), { id: "c" }, CUT);
    expect(next).toEqual([]);
  });
});
