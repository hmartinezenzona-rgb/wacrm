import { describe, expect, it } from "vitest";
import {
  estadoCounts,
  formatOperacionHora,
  historialCsv,
  historialCsvFilename,
  isSingleDay,
  periodoActivo,
  type HistorialFila,
} from "./operaciones-historial";

const fila = (over: Partial<HistorialFila> = {}): HistorialFila => ({
  dia: "2026-10-29",
  service_type: "remesa",
  status: "completed",
  cliente: "Ana",
  telefono: "5926000000",
  monto_gyd: 26000,
  beneficiario: null,
  tarjeta: null,
  operation_id: "11111111-aaaa",
  total: 1,
  servicio: "CUP",
  conversation_id: "c-1",
  operacion_at: "2026-10-29T18:32:00Z",
  estado_grupo: "completed",
  ...over,
});

describe("estadoCounts", () => {
  it("adds the four groups into Todas and zero-fills missing groups", () => {
    expect(estadoCounts([{ grupo: "completed", cantidad: 13 }, { grupo: "in_progress", cantidad: 4 }, { grupo: "incident", cantidad: 1 }])).toEqual({
      all: 18,
      completed: 13,
      in_progress: 4,
      incident: 1,
      cancelled: 0,
    });
  });
  it("is all zeros for no data and ignores unknown groups", () => {
    expect(estadoCounts([])).toEqual({ all: 0, completed: 0, in_progress: 0, incident: 0, cancelled: 0 });
    expect(estadoCounts([{ grupo: "weird", cantidad: 5 }]).all).toBe(0);
  });
  it("accepts counts that arrive as strings (bigint over the wire)", () => {
    expect(estadoCounts([{ grupo: "completed", cantidad: "7" as unknown as number }]).all).toBe(7);
  });
});

describe("isSingleDay", () => {
  it("is true only when both ends are the same date", () => {
    expect(isSingleDay("2026-10-29", "2026-10-29")).toBe(true);
    expect(isSingleDay("2026-10-28", "2026-10-29")).toBe(false);
    expect(isSingleDay("", "")).toBe(false);
    expect(isSingleDay("2026-10-29", "")).toBe(false);
  });
});

describe("formatOperacionHora", () => {
  // 18:32 UTC is 14:32 in Guyana (UTC-4, no DST).
  it("shows only the time in America/Guyana for a single day", () => {
    expect(formatOperacionHora("2026-10-29T18:32:00Z", true)).toBe("14:32");
  });
  it("shows dd/MM HH:mm when the range spans days, in Guyana", () => {
    expect(formatOperacionHora("2026-10-29T18:32:00Z", false)).toBe("29/10 14:32");
    // 02:10 UTC on the 30th is still the 29th at 22:10 in Guyana
    expect(formatOperacionHora("2026-10-30T02:10:00Z", false)).toBe("29/10 22:10");
  });
  it("returns a dash for a missing or invalid instant", () => {
    expect(formatOperacionHora(null, true)).toBe("—");
    expect(formatOperacionHora("nope", false)).toBe("—");
  });
});

describe("periodoActivo", () => {
  const periodos = [
    { orden: 1, desde: "2026-10-29", hasta: "2026-10-29" },
    { orden: 3, desde: "2026-10-26", hasta: "2026-11-01" },
  ];
  it("finds the period whose range is exactly the selected one", () => {
    expect(periodoActivo(periodos, "2026-10-29", "2026-10-29")).toBe(1);
    expect(periodoActivo(periodos, "2026-10-26", "2026-11-01")).toBe(3);
  });
  it("is null for a custom range or an empty one", () => {
    expect(periodoActivo(periodos, "2026-10-27", "2026-10-29")).toBeNull();
    expect(periodoActivo(periodos, "", "")).toBeNull();
  });
});

describe("historialCsvFilename", () => {
  it("carries the date range", () => {
    expect(historialCsvFilename("2026-10-01", "2026-10-29")).toBe("operaciones_2026-10-01_2026-10-29.csv");
    expect(historialCsvFilename("2026-10-29", "2026-10-29")).toBe("operaciones_2026-10-29.csv");
    expect(historialCsvFilename("2026-10-01", "")).toBe("operaciones_desde_2026-10-01.csv");
    expect(historialCsvFilename("", "2026-10-29")).toBe("operaciones_hasta_2026-10-29.csv");
    expect(historialCsvFilename("", "")).toBe("operaciones_todas.csv");
  });
});

describe("historialCsv", () => {
  const labels = (s: string) => (s === "completed" ? "Completada" : s);
  it("starts with a UTF-8 BOM and a header, one row per history row, Guyana time", () => {
    const csv = historialCsv([fila({ beneficiario: "Luis", tarjeta: "9205****9412" })], labels);
    expect(csv.startsWith("﻿")).toBe(true);
    const lines = csv.slice(1).split("\r\n");
    expect(lines[0]).toBe("fecha_hora_guyana,operacion_id,cliente,telefono,servicio,monto_gyd,destino,estado");
    expect(lines[1]).toBe("2026-10-29 14:32,11111111-aaaa,Ana,5926000000,CUP,26000,Luis · 9205****9412,Completada");
  });
  it("escapes commas, quotes and line breaks, and neutralizes formula starts", () => {
    const csv = historialCsv([fila({ cliente: 'Ana, "la" \n Perez', beneficiario: "=SUM(A1)" })], labels);
    const body = csv.slice(1).split("\r\n").slice(1).join("\r\n");
    expect(body).toContain('"Ana, ""la"" \n Perez"');
    expect(body).toContain("'=SUM(A1)");
  });
  it("keeps a phone that starts with + as it is", () => {
    expect(historialCsv([fila({ telefono: "+592 600 0000" })], labels)).toContain(",+592 600 0000,");
  });
  it("falls back to the service_type and to the raw status when there is no label", () => {
    const csv = historialCsv([fila({ servicio: null, service_type: "combo", status: "brand_new" })], labels);
    expect(csv).toContain(",combo,");
    expect(csv.trimEnd().endsWith(",brand_new")).toBe(true);
  });
  it("is only the header for no rows", () => {
    expect(historialCsv([], labels).slice(1)).toBe("fecha_hora_guyana,operacion_id,cliente,telefono,servicio,monto_gyd,destino,estado\r\n");
  });
});
