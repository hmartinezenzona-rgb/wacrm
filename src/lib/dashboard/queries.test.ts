import { describe, expect, it, vi } from "vitest";
import { loadLedgerProfit } from "./queries";

function dbReturning(rows: unknown[]) {
  const calls: Array<[string, ...unknown[]]> = [];
  const builder: Record<string, unknown> = {};
  for (const method of ["select", "eq", "in", "neq", "gte"]) {
    builder[method] = vi.fn((...args: unknown[]) => {
      calls.push([method, ...args]);
      return builder;
    });
  }
  builder.then = (resolve: (value: { data: unknown; error: null }) => unknown) => Promise.resolve({ data: rows, error: null }).then(resolve);
  return { db: { from: vi.fn(() => builder) } as never, calls };
}

const row = (overrides: Record<string, unknown>) => ({
  id: "e", account_id: "a", source: "completed_operation", status: "completed", operation_id: "op-1", entry_date: "2026-10-06",
  customer_name: "Ana", service: "ZELLE", amount: "100", amount_currency: "USD", facturado_gyd: "1000", invertido_gyd: "800",
  retorno_gyd: "200", cup_global_rate: null, cup_rate: null, usdt_buy_gyd: null, usdt_sell_gyd: null, rate_version_id: null,
  missing_inputs: null, delivery_mode: null, voided_at: null, void_reason: null, completed_at: null, created_at: "2026-10-06T00:00:00Z",
  ...overrides,
});

describe("loadLedgerProfit", () => {
  it("reads the bot's operations and the manual Calculator lines (migration 228), never voids", async () => {
    const { db, calls } = dbReturning([
      row({ id: "bot", operation_id: "op-1", customer_name: "Ana", facturado_gyd: "1000" }),
      row({ id: "man", source: "manual", operation_id: null, customer_name: "Ana", facturado_gyd: "500" }),
    ]);

    const result = await loadLedgerProfit(db);

    expect(calls).toContainEqual(["in", "source", ["completed_operation", "manual"]]);
    expect(calls).toContainEqual(["neq", "status", "void"]);
    expect(calls.some(([method, column, value]) => method === "eq" && column === "source" && value === "completed_operation")).toBe(false);
    expect(result.topClients).toEqual([{ customerName: "Ana", operationCount: 2, facturadoGyd: 1500 }]);
  });
});
