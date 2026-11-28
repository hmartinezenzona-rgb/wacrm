import { describe, expect, it } from "vitest";
import { entryGroup, filterRegistros, NO_FILTERS, registroTotals, serviceOptions, statusCounts, type RegistroEntry } from "./registros";

let seq = 0;
function row(overrides: Partial<RegistroEntry> = {}): RegistroEntry {
  seq += 1;
  return {
    id: `r${seq}`, operationId: `op-${seq}`, source: "completed_operation", status: "completed", service: "ZELLE", customerName: "Ana",
    entryDate: "2026-10-27", facturadoGyd: 100, invertidoGyd: 80, retornoGyd: 20, missingRates: [], ...overrides,
  };
}

const ROWS = [
  row({ customerName: "Ana" }),
  row({ customerName: "Bruno", service: "CUP", source: "manual", operationId: null }),
  row({ customerName: "ana ", service: "CUP" }),
  row({ status: "verified_pending", service: "ZELLE", missingRates: ["usdt_buy_gyd"], facturadoGyd: 50, invertidoGyd: null, retornoGyd: null }),
  row({ status: "verified_pending", service: "COMBO", missingRates: ["combo_cost"], customerName: "Carla", facturadoGyd: null, invertidoGyd: null, retornoGyd: null }),
];

describe("entryGroup", () => {
  it("separates completed lines, lines waiting for a rate and other pending lines", () => {
    expect(ROWS.map(entryGroup)).toEqual(["completed", "completed", "completed", "sinTasa", "pending"]);
  });
});

describe("filterRegistros", () => {
  it("keeps everything with no filters", () => {
    expect(filterRegistros(ROWS, NO_FILTERS)).toHaveLength(5);
  });

  it("filters by status chip, 'A mano' being the manual lines of any status", () => {
    expect(filterRegistros(ROWS, { ...NO_FILTERS, status: "completed" })).toHaveLength(3);
    expect(filterRegistros(ROWS, { ...NO_FILTERS, status: "sinTasa" })).toHaveLength(1);
    expect(filterRegistros(ROWS, { ...NO_FILTERS, status: "pending" })).toHaveLength(1);
    expect(filterRegistros(ROWS, { ...NO_FILTERS, status: "manual" }).map((r) => r.customerName)).toEqual(["Bruno"]);
  });

  it("filters by service and by client, ignoring case and surrounding spaces", () => {
    expect(filterRegistros(ROWS, { ...NO_FILTERS, service: "CUP" })).toHaveLength(2);
    expect(filterRegistros(ROWS, { ...NO_FILTERS, client: "ANA" }).map((r) => r.id)).toEqual([ROWS[0]!.id, ROWS[2]!.id, ROWS[3]!.id]);
  });

  it("searches the client name and the operation id", () => {
    expect(filterRegistros(ROWS, { ...NO_FILTERS, query: "brun" })).toHaveLength(1);
    expect(filterRegistros(ROWS, { ...NO_FILTERS, query: ROWS[0]!.operationId!.toUpperCase() })).toEqual([ROWS[0]]);
    expect(filterRegistros(ROWS, { ...NO_FILTERS, query: "nadie" })).toEqual([]);
  });

  it("combines the filters", () => {
    expect(filterRegistros(ROWS, { status: "completed", service: "CUP", client: "ana", query: "" })).toEqual([ROWS[2]]);
  });
});

describe("statusCounts", () => {
  it("counts each chip over the lines the other filters leave", () => {
    expect(statusCounts(ROWS, NO_FILTERS)).toEqual({ all: 5, completed: 3, pending: 1, sinTasa: 1, manual: 1 });
    expect(statusCounts(ROWS, { ...NO_FILTERS, service: "CUP" })).toEqual({ all: 2, completed: 2, pending: 0, sinTasa: 0, manual: 1 });
  });

  it("ignores the status already chosen", () => {
    expect(statusCounts(ROWS, { ...NO_FILTERS, status: "sinTasa" }).all).toBe(5);
  });
});

describe("registroTotals", () => {
  it("adds the completed lines only: a line waiting for a rate never counts", () => {
    expect(registroTotals(ROWS)).toEqual({ facturado: 300, invertido: 240, retorno: 60, ops: 3 });
    expect(registroTotals([])).toEqual({ facturado: 0, invertido: 0, retorno: 0, ops: 0 });
  });
});

describe("serviceOptions", () => {
  it("lists each service once, in the order it first appears", () => {
    expect(serviceOptions(ROWS)).toEqual(["ZELLE", "CUP", "COMBO"]);
  });
});
