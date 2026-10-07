import { describe, expect, it } from "vitest";
import { closeCsvFilename, financialCloseToCsv } from "./csv";
import type { CloseEntry, ExcludedEntry, FinancialClose } from "./read-model";

function entry(overrides: Partial<CloseEntry> = {}): CloseEntry {
  return {
    id: "e1",
    operationId: "op-1",
    source: "completed_operation",
    day: "2026-09-22",
    completedAt: "2026-09-22T15:05:00Z",
    customerName: "Ana",
    service: "CUP",
    amount: 3000,
    amountCurrency: "CUP",
    cupRate: 975,
    cupGlobalRate: 3,
    usdtBuyGyd: null,
    usdtSellGyd: null,
    rateVersionId: "rv1",
    facturadoGyd: 1000.5,
    invertidoGyd: 700,
    retornoGyd: 300.5,
    deliveryMode: "proof_sent",
    actorUserId: "u1",
    actorName: "Humberto",
    ...overrides,
  };
}

function excluded(overrides: Partial<ExcludedEntry> = {}): ExcludedEntry {
  return {
    ...entry({ id: "e3", operationId: "op-3", facturadoGyd: null, invertidoGyd: null, retornoGyd: null }),
    status: "verified_pending",
    voidReason: null,
    voidedAt: null,
    missingInputs: ["cup_rate", "usdt_sell_gyd"],
    ...overrides,
  };
}

function close(detail: CloseEntry[], excl: ExcludedEntry[] = []): FinancialClose {
  return {
    range: { desde: "2026-09-21", hasta: "2026-09-27" },
    timeZone: "America/Guyana",
    totals: { operations: detail.length, facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 },
    byService: [],
    byDay: [],
    detail,
    excluded: excl,
  };
}

function rows(csv: string): string[] {
  return csv.replace(/^﻿/, "").trimEnd().split("\r\n");
}

describe("financialCloseToCsv", () => {
  it("starts with a BOM so Excel reads accents, and has one header row", () => {
    const csv = financialCloseToCsv(close([]));
    expect(csv.startsWith("﻿")).toBe(true);
    expect(rows(csv)).toHaveLength(1);
    expect(rows(csv)[0].split(",")[0]).toBe("estado");
  });

  it("writes one row per entry with raw numbers and the Guyana time", () => {
    const [header, row] = rows(financialCloseToCsv(close([entry()])));
    const cols = header.split(",");
    const values = row.split(",");
    const get = (name: string) => values[cols.indexOf(name)];
    expect(get("estado")).toBe("completada");
    expect(get("dia")).toBe("2026-09-22");
    expect(get("hora_guyana")).toBe("11:05");
    expect(get("operacion_id")).toBe("op-1");
    expect(get("monto")).toBe("3000");
    expect(get("tasa_cup")).toBe("975");
    expect(get("facturado_gyd")).toBe("1000.5");
    expect(get("retorno_gyd")).toBe("300.5");
    expect(get("usdt_venta_gyd")).toBe("");
    expect(get("entrega")).toBe("proof_sent");
    expect(get("entregado_por")).toBe("Humberto");
  });

  it("says where each row came from: the bot's operation or a line typed in the Calculator", () => {
    const [header, chat, manual] = rows(
      financialCloseToCsv(close([entry(), entry({ id: "m1", operationId: null, source: "manual", deliveryMode: null })])),
    );
    const cols = header.split(",");
    expect(chat.split(",")[cols.indexOf("origen")]).toBe("automatica");
    const values = manual.split(",");
    expect(values[cols.indexOf("origen")]).toBe("manual");
    expect(values[cols.indexOf("operacion_id")]).toBe("");
  });

  it("appends voided and pending entries after the completed ones, with their state", () => {
    const csv = financialCloseToCsv(
      close([entry()], [excluded(), excluded({ id: "e4", status: "void", voidReason: "duplicada", missingInputs: [] })]),
    );
    const lines = rows(csv);
    expect(lines).toHaveLength(4);
    expect(lines[2]).toContain("pendiente_tasa");
    expect(lines[2]).toContain("cup_rate|usdt_sell_gyd");
    expect(lines[3]).toContain("anulada");
    expect(lines[3]).toContain("duplicada");
  });

  it("quotes commas, quotes and line breaks", () => {
    const csv = financialCloseToCsv(close([entry({ customerName: 'Pérez, "Juan"\nhijo' })]));
    expect(csv).toContain('"Pérez, ""Juan""\nhijo"');
  });

  it("neutralises cells that a spreadsheet would run as a formula", () => {
    const csv = financialCloseToCsv(close([entry({ customerName: "=HYPERLINK(\"x\")", actorName: "+1 555" })]));
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
    expect(csv).toContain("'+1 555");
  });

  it("keeps negative numbers as numbers, not as neutralised text", () => {
    const [header, row] = rows(financialCloseToCsv(close([entry({ retornoGyd: -120 })])));
    expect(row.split(",")[header.split(",").indexOf("retorno_gyd")]).toBe("-120");
  });
});

describe("closeCsvFilename", () => {
  it("names the file after the range", () => {
    expect(closeCsvFilename({ desde: "2026-09-21", hasta: "2026-09-27" })).toBe(
      "cierre-financiero_2026-09-21_2026-09-27.csv",
    );
  });
});
