// @vitest-environment jsdom
// The three profit charts of Finanzas > Cierres: they render from the series, stay out when there is nothing to
// compare, are named for assistive tech and their tooltips carry the figures the brief asks for.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
import type { CalculatorWeekSummary } from "@/lib/calculator/weeks";
import type { FinancialClose } from "@/lib/financial-close/read-model";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, es as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      return Object.entries(params ?? {}).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));
vi.mock("@/hooks/use-service-name", () => ({ useServiceName: () => (service: string) => service.toLowerCase() }));

// jsdom has no layout: give the responsive container a fixed size so recharts draws.
vi.mock("recharts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("recharts")>();
  return {
    ...actual,
    ResponsiveContainer: ({ children }: { children: React.ReactElement<{ width?: number; height?: number }> }) =>
      React.cloneElement(children, { width: 600, height: 280 }),
  };
});

import { fmtGyd } from "@/components/resumen/financial-close-format";
import { formatNumber } from "@/lib/format-number";
import { DayTooltip, ProfitByDayChart, ProfitByServiceChart, ServiceTooltip, WeekTooltip, WeeklyProfitChart } from "./profit-charts";

const plain = (n: number) => formatNumber(n, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const agg = (operations: number, facturadoGyd: number, invertidoGyd: number, retornoGyd: number) => ({ operations, facturadoGyd, invertidoGyd, retornoGyd });
const BY_DAY: FinancialClose["byDay"] = [
  { day: "2026-09-21", ...agg(1, 500, 400, 100) },
  { day: "2026-09-22", ...agg(3, 900, 1000, -100) },
  { day: "2026-09-23", ...agg(2, 800, 600, 200) },
];
const BY_SERVICE: FinancialClose["byService"] = [
  { service: "CUP", ...agg(1, 1000, 700, 300) },
  { service: "ZELLE", ...agg(2, 2000, 1500, 500) },
];
const week = (id: string, cutAt: string, retorno: number): CalculatorWeekSummary => ({
  id,
  cutAt,
  periodo: `Semana ${id}`,
  manualTotals: { facturadoGyd: 100, invertidoGyd: 0, retornoGyd: retorno },
  chatTotals: { facturadoGyd: 200, invertidoGyd: 0, retornoGyd: 0, count: 1 },
});
const WEEKS = [week("a", "2026-10-05T15:00:00.000Z", 10), week("b", "2026-10-12T15:00:00.000Z", 30), week("c", "2026-10-19T15:00:00.000Z", 20)];

async function mount(element: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(element));
  return node;
}

afterEach(() => document.body.replaceChildren());

describe("ProfitByDayChart", () => {
  it("draws one bar per day in one colour, under a titled, labelled figure", async () => {
    const node = await mount(<ProfitByDayChart byDay={BY_DAY} />);
    const figure = node.querySelector("figure")!;
    expect(figure.getAttribute("aria-label")).toBe(es.Finanzas.graficos.gananciaDia.aria);
    expect(figure.textContent).toContain("Ganancia por día");
    const bars = node.querySelectorAll(".recharts-bar-rectangle path");
    expect(bars).toHaveLength(3);
    expect(new Set([...bars].map((b) => b.getAttribute("fill"))).size).toBe(1);
    expect(node.querySelector(".recharts-legend-wrapper")).toBeNull();
  });

  it("is hidden with no data or a single day", async () => {
    expect((await mount(<ProfitByDayChart byDay={[]} />)).querySelector("figure")).toBeNull();
    expect((await mount(<ProfitByDayChart byDay={[BY_DAY[0]!]} />)).querySelector("figure")).toBeNull();
  });
});

describe("ProfitByServiceChart", () => {
  it("labels each bar with its value, highest profit first, in one colour", async () => {
    const node = await mount(<ProfitByServiceChart byService={BY_SERVICE} />);
    expect(node.querySelector("figure")!.getAttribute("aria-label")).toBe(es.Finanzas.graficos.gananciaServicio.aria);
    const values = [...node.querySelectorAll(".recharts-label-list text")].map((n) => n.textContent);
    expect(values).toEqual([plain(500), plain(300)]);
    const bars = node.querySelectorAll(".recharts-bar-rectangle path");
    expect(new Set([...bars].map((b) => b.getAttribute("fill"))).size).toBe(1);
  });

  it("is hidden with fewer than two services", async () => {
    expect((await mount(<ProfitByServiceChart byService={[]} />)).querySelector("figure")).toBeNull();
    expect((await mount(<ProfitByServiceChart byService={[BY_SERVICE[0]!]} />)).querySelector("figure")).toBeNull();
  });
});

describe("WeeklyProfitChart", () => {
  it("draws one line with a marker per week", async () => {
    const node = await mount(<WeeklyProfitChart weeks={WEEKS} />);
    expect(node.querySelector("figure")!.getAttribute("aria-label")).toBe(es.Finanzas.graficos.gananciaSemana.aria);
    expect(node.querySelectorAll(".recharts-line-curve")).toHaveLength(1);
    expect(node.querySelectorAll(".recharts-line-dots circle")).toHaveLength(3);
  });

  it("is hidden with fewer than two weeks", async () => {
    expect((await mount(<WeeklyProfitChart weeks={[]} />)).querySelector("figure")).toBeNull();
    expect((await mount(<WeeklyProfitChart weeks={[WEEKS[0]!]} />)).querySelector("figure")).toBeNull();
  });
});

describe("tooltips", () => {
  const text = async (el: React.ReactElement) => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    await act(async () => createRoot(node).render(el));
    return node.textContent;
  };

  it("day: the day, the profit and the number of operations", async () => {
    const out = await text(<DayTooltip active payload={[{ payload: { day: "2026-09-22", label: "22 sep", retorno: -100, operations: 3 } }]} />);
    expect(out).toContain("22 sep");
    expect(out).toContain(fmtGyd(-100));
    expect(out).toContain("Operaciones: 3");
  });

  it("service: facturado, invertido, retorno and margen", async () => {
    const out = await text(<ServiceTooltip active payload={[{ payload: { service: "ZELLE", facturado: 2000, invertido: 1500, retorno: 500, margin: "25.0", operations: 2 } }]} />);
    for (const part of ["zelle", fmtGyd(2000), fmtGyd(1500), fmtGyd(500), "Margen 25.0%"]) expect(out).toContain(part);
  });

  it("week: facturado and retorno of that week", async () => {
    const out = await text(<WeekTooltip active payload={[{ payload: { id: "b", label: "12 oct", cutDate: "2026-10-12", periodo: "Semana b", facturado: 300, retorno: 30 } }]} />);
    for (const part of ["Semana b", "2026-10-12", fmtGyd(300), fmtGyd(30)]) expect(out).toContain(part);
  });

  it("render nothing when inactive", async () => {
    expect(await text(<DayTooltip active={false} payload={[]} />)).toBe("");
  });
});
