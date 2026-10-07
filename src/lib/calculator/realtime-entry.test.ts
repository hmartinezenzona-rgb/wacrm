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
      operationId: "op-1",
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
      operationId: "op-1",
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
    });
  });

  it("returns null for a manual entry (source <> completed_operation)", () => {
    expect(mapRealtimeCalculatorEntry(row({ source: "manual" }))).toBeNull();
  });

  it("returns null for a voided row, mirroring the GET route's status<>'void' filter", () => {
    expect(mapRealtimeCalculatorEntry(row({ status: "void" }))).toBeNull();
  });
});

describe("applyCalculatorEntryRealtimeEvent", () => {
  it("INSERT: prepends a newly-qualifying entry", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "old", operationId: "op-old", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "2026-09-28", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ id: "entry-new" }), null);
    expect(next.map((e) => e.id)).toEqual(["entry-new", "old"]);
  });

  it("INSERT of a manual/voided row is a no-op", () => {
    const existing: ChatCalculatorEntry[] = [];
    const next = applyCalculatorEntryRealtimeEvent(existing, "INSERT", row({ source: "manual" }), null);
    expect(next).toEqual([]);
  });

  it("UPDATE: replaces an existing entry in place, keeping array position", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
      { id: "b", operationId: "op-b", status: "verified_pending", service: "ZELLE", customerName: "B", amount: 100, amountCurrency: "USD", entryDate: "d", facturadoGyd: null, invertidoGyd: null, retornoGyd: null, missingRates: ["usdtSellGyd"] },
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
      { id: "a", operationId: "op-a", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "UPDATE", row({ id: "a", status: "void" }), { id: "a" });
    expect(next).toEqual([]);
  });

  it("DELETE removes the entry by the old row's id", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    const next = applyCalculatorEntryRealtimeEvent(existing, "DELETE", null, { id: "a" });
    expect(next).toEqual([]);
  });

  it("DELETE with no old id is a no-op", () => {
    const existing: ChatCalculatorEntry[] = [
      { id: "a", operationId: "op-a", status: "completed", service: "CUP", customerName: "A", amount: 1, amountCurrency: "CUP", entryDate: "d", facturadoGyd: 1, invertidoGyd: 1, retornoGyd: 0, missingRates: [] },
    ];
    expect(applyCalculatorEntryRealtimeEvent(existing, "DELETE", null, null)).toEqual(existing);
  });
});

describe("applyCalculatorEntryRealtimeEvent with the weekly cut", () => {
  const CUT = "2026-10-03T12:00:00.000Z";
  const shown: ChatCalculatorEntry = {
    id: "pending-1", operationId: "op-p", status: "verified_pending", service: "CUP", customerName: "P", amount: 1,
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
