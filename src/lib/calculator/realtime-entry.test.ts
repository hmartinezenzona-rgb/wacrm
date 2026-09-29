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
