// ============================================================
// CSV export of the financial close: every completed ledger entry of the
// period, then the voided and rate-pending ones, one row each, with the
// same numbers the screen shows. Numbers are raw (no thousands separator)
// so a spreadsheet can sum them.
// ============================================================

import { guyanaTime, type DateRange } from "./periods";
import type { CloseEntry, ExcludedEntry, FinancialClose } from "./read-model";

const COLUMNS = [
  "estado",
  "dia",
  "hora_guyana",
  "completado_utc",
  "operacion_id",
  "cliente",
  "servicio",
  "monto",
  "moneda",
  "tasa_cup",
  "tasa_cup_global",
  "usdt_compra_gyd",
  "usdt_venta_gyd",
  "version_tasa",
  "facturado_gyd",
  "invertido_gyd",
  "retorno_gyd",
  "entrega",
  "entregado_por",
  "motivo_anulacion",
  "faltan_tasas",
] as const;

const STATE_LABEL: Record<"completed" | ExcludedEntry["status"], string> = {
  completed: "completada",
  void: "anulada",
  verified_pending: "pendiente_tasa",
};

type Cell = string | number | null;

function textCell(value: string | null): string {
  if (value === null || value === "") return "";
  // A cell starting like a formula would run in Excel/Sheets (CSV injection).
  const safe = /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  return /[",\r\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

function cell(value: Cell): string {
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "";
  return textCell(value);
}

function row(entry: CloseEntry, state: keyof typeof STATE_LABEL, extra: { reason: string | null; missing: string[] }): string {
  const values: Cell[] = [
    STATE_LABEL[state],
    entry.day,
    entry.completedAt ? guyanaTime(entry.completedAt) : null,
    entry.completedAt,
    entry.operationId,
    entry.customerName,
    entry.service,
    entry.amount,
    entry.amountCurrency,
    entry.cupRate,
    entry.cupGlobalRate,
    entry.usdtBuyGyd,
    entry.usdtSellGyd,
    entry.rateVersionId,
    entry.facturadoGyd,
    entry.invertidoGyd,
    entry.retornoGyd,
    entry.deliveryMode,
    entry.actorName,
    extra.reason,
    extra.missing.length ? extra.missing.join("|") : null,
  ];
  return values.map(cell).join(",");
}

export function financialCloseToCsv(close: FinancialClose): string {
  const lines = [
    COLUMNS.join(","),
    ...close.detail.map((e) => row(e, "completed", { reason: null, missing: [] })),
    ...close.excluded.map((e) => row(e, e.status, { reason: e.voidReason, missing: e.missingInputs })),
  ];
  // BOM so Excel opens the UTF-8 accents correctly.
  return `﻿${lines.join("\r\n")}\r\n`;
}

export function closeCsvFilename(range: DateRange): string {
  return `cierre-financiero_${range.desde}_${range.hasta}.csv`;
}
