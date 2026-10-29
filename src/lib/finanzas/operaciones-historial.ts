// Pure figures for Finanzas > Operaciones: the history rows of `crm_historial_operaciones` (migration 351), the status
// chip counts, the Guyana time of an operation and the CSV export. No React, no I/O.

import { historialDestino } from "@/lib/resumen/historial-destino";

export interface HistorialFila {
  dia: string;
  service_type: string;
  status: string;
  cliente: string | null;
  telefono: string | null;
  monto_gyd: number;
  /** Solo remesas: null en recargas y demás servicios. */
  beneficiario: string | null;
  /** Ya viene enmascarada (9205****9412). Null sin tarjeta. */
  tarjeta: string | null;
  operation_id: string;
  /** Filas que hay en TODO el filtro, no en esta página. */
  total: number;
  servicio?: string | null;
  conversation_id: string | null;
  /** Instante de la operación (completed_at, o updated_at si sigue abierta). */
  operacion_at: string | null;
  estado_grupo: string;
}

export const ESTADO_GRUPOS = ["completed", "in_progress", "incident", "cancelled"] as const;
export type EstadoGrupo = (typeof ESTADO_GRUPOS)[number];
export type EstadoFiltro = "all" | EstadoGrupo;
export type EstadoCounts = Record<EstadoFiltro, number>;

/** Counts per status group from `crm_historial_estados`; "all" is their sum. Unknown groups are ignored. */
export function estadoCounts(rows: ReadonlyArray<{ grupo: string; cantidad: number }>): EstadoCounts {
  const out: EstadoCounts = { all: 0, completed: 0, in_progress: 0, incident: 0, cancelled: 0 };
  for (const r of rows) {
    if (!(ESTADO_GRUPOS as ReadonlyArray<string>).includes(r.grupo)) continue;
    const n = Number(r.cantidad) || 0;
    out[r.grupo as EstadoGrupo] += n;
    out.all += n;
  }
  return out;
}

export function isSingleDay(desde: string, hasta: string): boolean {
  return Boolean(desde) && desde === hasta;
}

const GUYANA = "America/Guyana";

/** "HH:mm" for a single-day range, "dd/MM HH:mm" otherwise, always in Guyana time. */
export function formatOperacionHora(iso: string | null | undefined, singleDay: boolean): string {
  if (!iso) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "—";
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone: GUYANA,
      day: "2-digit",
      month: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(date)
      .map((p) => [p.type, p.value]),
  ) as Record<string, string>;
  const time = `${parts.hour}:${parts.minute}`;
  return singleDay ? time : `${parts.day}/${parts.month} ${time}`;
}

/** The `orden` of the period card whose range is exactly desde..hasta, or null (custom or empty range). */
export function periodoActivo(
  periodos: ReadonlyArray<{ orden: number; desde: string; hasta: string }>,
  desde: string,
  hasta: string,
): number | null {
  if (!desde || !hasta) return null;
  return periodos.find((p) => p.desde === desde && p.hasta === hasta)?.orden ?? null;
}

export function historialCsvFilename(desde: string, hasta: string): string {
  if (desde && hasta) return desde === hasta ? `operaciones_${desde}.csv` : `operaciones_${desde}_${hasta}.csv`;
  if (desde) return `operaciones_desde_${desde}.csv`;
  if (hasta) return `operaciones_hasta_${hasta}.csv`;
  return "operaciones_todas.csv";
}

const CSV_COLUMNS = ["fecha_hora_guyana", "operacion_id", "cliente", "telefono", "servicio", "monto_gyd", "destino", "estado"];

function csvCell(value: string | number | null | undefined, opts: { phone?: boolean } = {}): string {
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "";
  if (value === null || value === undefined || value === "") return "";
  // A cell starting like a formula would run in Excel/Sheets (CSV injection); a phone may legitimately start with "+".
  const phoneLike = opts.phone && /^\+?[\d ()-]+$/.test(value);
  const safe = !phoneLike && /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  return /[",\r\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

function guyanaStamp(iso: string | null): string {
  if (!iso || Number.isNaN(new Date(iso).getTime())) return "";
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: GUYANA,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(new Date(iso))
      .map((x) => [x.type, x.value]),
  ) as Record<string, string>;
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`;
}

/** UTF-8 CSV (with BOM) of history rows; numbers are raw so a spreadsheet can sum them. */
export function historialCsv(rows: ReadonlyArray<HistorialFila>, statusLabel: (status: string) => string): string {
  const lines = rows.map((f) =>
    [
      csvCell(guyanaStamp(f.operacion_at) || f.dia),
      csvCell(f.operation_id),
      csvCell(f.cliente),
      csvCell(f.telefono, { phone: true }),
      csvCell(f.servicio ?? f.service_type),
      csvCell(f.monto_gyd),
      csvCell(historialDestino(f) === "—" ? "" : historialDestino(f)),
      csvCell(statusLabel(f.status)),
    ].join(","),
  );
  return `﻿${[CSV_COLUMNS.join(","), ...lines].join("\r\n")}\r\n`;
}
