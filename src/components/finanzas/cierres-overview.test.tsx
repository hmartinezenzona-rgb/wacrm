// @vitest-environment jsdom
// The Cierres overview: period chips, KPI cards, profit per closed week, the selected week, profit by service, the
// compact archived-weeks table and the collapsible period close. Figures themselves are tested in
// src/lib/finanzas/cierres-overview.test.ts.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import esMessages from "../../../messages/es.json";
import { num, pctText } from "@/lib/finanzas/number-format";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// jsdom has no layout: give the responsive container a fixed size so recharts draws.
vi.mock("recharts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("recharts")>();
  return {
    ...actual,
    ResponsiveContainer: ({ children }: { children: React.ReactElement<{ width?: number; height?: number }> }) =>
      React.cloneElement(children, { width: 700, height: 260 }),
  };
});
vi.mock("@/components/resumen/financial-close-section", () => ({ FinancialCloseSection: () => <section data-testid="close" /> }));

import { CierresOverview } from "./cierres-overview";

const n = (value: number) => num(Math.round(value));

// Eight weeks cut on Mondays 7 Sep ... 26 Oct 2026; week i earns (i + 1) * 1000 over entries on its Tuesday and Saturday.
const monday = (i: number) => new Date(Date.UTC(2026, 8, 7 + 7 * i, 15));
const isoDay = (date: Date, shift: number) => new Date(date.getTime() + shift * 86_400_000).toISOString().slice(0, 10);

function summary(i: number) {
  const profit = (i + 1) * 1000;
  return {
    id: `w${i}`,
    cutAt: monday(i).toISOString(),
    periodo: `SEMANA ${i + 1}`,
    manualTotals: { facturadoGyd: profit * 10, invertidoGyd: profit * 9, retornoGyd: profit },
    chatTotals: { count: 0, facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 },
  };
}
function detail(i: number) {
  const profit = (i + 1) * 1000;
  const entry = (suffix: string, shift: number, service: string, retornoGyd: number) => ({
    id: `e${i}${suffix}`, operationId: null, source: "manual", status: "completed", service, customerName: "Ana", amount: 1,
    amountCurrency: "GYD", entryDate: isoDay(monday(i), shift), facturadoGyd: retornoGyd * 10, invertidoGyd: retornoGyd * 9, retornoGyd, missingRates: [],
  });
  return {
    ...summary(i), rawText: `texto ${i}`,
    entries: [entry("a", -6, "ZELLE", profit * 0.6), entry("b", -2, "CUP", profit * 0.4)],
  };
}
const ALL = Array.from({ length: 8 }, (_, i) => i);

function fetchMock(opts: { weeks?: number[]; detailStatus?: (id: string) => number; listStatus?: number } = {}) {
  const weeks = opts.weeks ?? ALL;
  return vi.fn((input: RequestInfo | URL) => {
    const url = String(input);
    if (url === "/api/calculadora/weeks") {
      if (opts.listStatus && opts.listStatus !== 200) return Promise.resolve(new Response("{}", { status: opts.listStatus }));
      return Promise.resolve(new Response(JSON.stringify({ weeks: weeks.map(summary) })));
    }
    const m = /^\/api\/calculadora\/weeks\/(w(\d+))$/.exec(url);
    if (m) {
      const status = opts.detailStatus?.(m[1]!) ?? 200;
      return Promise.resolve(new Response(JSON.stringify(status === 200 ? { week: detail(Number(m[2])) } : {}), { status }));
    }
    return Promise.reject(new Error(`Unhandled fetch ${url}`));
  });
}

let container: HTMLDivElement | null = null;
let root: ReturnType<typeof createRoot> | null = null;
const flush = () => act(async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); });

function ui(active: boolean) {
  return (
    <NextIntlClientProvider locale="es" messages={esMessages}>
      <CierresOverview active={active} />
    </NextIntlClientProvider>
  );
}
async function render(mock = fetchMock(), active = true) {
  vi.stubGlobal("fetch", mock);
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  await act(async () => root!.render(ui(active)));
  await flush();
  return mock;
}

const text = () => container!.textContent!.replace(/\s+/g, " ");
const button = (label: string) => [...container!.querySelectorAll("button")].find((b) => b.textContent?.trim() === label) as HTMLButtonElement;
const click = (el: Element) => act(async () => { el.dispatchEvent(new MouseEvent("click", { bubbles: true })); });
const selectedPanel = () => container!.querySelector("[data-testid=cierres-seleccion]") as HTMLElement;

beforeEach(() => vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-10-28T15:00:00Z") }));
afterEach(() => {
  act(() => root?.unmount());
  container?.remove();
  container = null;
  root = null;
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("CierresOverview", () => {
  it("shows a loading state, then reads the list and the detail of each week once", async () => {
    const mock = fetchMock();
    vi.stubGlobal("fetch", mock);
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    act(() => root!.render(ui(true)));
    expect(container.querySelector("[aria-busy=true]")).not.toBeNull();
    await flush();
    expect(container.querySelector("[aria-busy=true]")).toBeNull();
    const urls = mock.mock.calls.map(([u]) => String(u));
    expect(urls.filter((u) => u === "/api/calculadora/weeks")).toHaveLength(1);
    expect(urls.filter((u) => u.startsWith("/api/calculadora/weeks/"))).toHaveLength(8);
  });

  it("has period chips with aria-pressed, the last 12 weeks by default", async () => {
    await render();
    const chips = [...container!.querySelectorAll("[aria-label=Periodo] button")] as HTMLButtonElement[];
    expect(chips.map((c) => c.textContent)).toEqual(["Últimas 12 semanas", "Este mes", "Mes pasado", "Todo"]);
    expect(chips.map((c) => c.getAttribute("aria-pressed"))).toEqual(["true", "false", "false", "false"]);
  });

  it("filters the weeks by the chip: this month keeps the October weeks, last month the September ones", async () => {
    await render();
    expect(container!.querySelectorAll("[data-testid=cierres-tabla] tbody tr")).toHaveLength(6); // 8 weeks, 6 shown
    await click(button("Este mes"));
    expect(button("Este mes").getAttribute("aria-pressed")).toBe("true");
    expect(button("Últimas 12 semanas").getAttribute("aria-pressed")).toBe("false");
    // the weeks cut on 5, 12, 19 and 26 Oct end (last entry) on 3, 10, 17 and 24 Oct
    expect(container!.querySelectorAll("[data-testid=cierres-tabla] tbody tr")).toHaveLength(4);
    await click(button("Mes pasado"));
    expect(container!.querySelectorAll("[data-testid=cierres-tabla] tbody tr")).toHaveLength(4);
    expect(text()).toContain("SEMANA 1");
    expect(text()).not.toContain("SEMANA 8");
  });

  it("says so when the chosen period has no weeks, and keeps the chips", async () => {
    await render(fetchMock({ weeks: [0, 1] })); // September only
    await click(button("Este mes"));
    expect(text()).toContain("No hay semanas archivadas en este periodo.");
    expect(button("Todo")).toBeDefined();
  });

  it("shows the four KPI cards", async () => {
    await render();
    // profit 1000 + ... + 8000 = 36000 over 8 weeks; billed 360000; margin 10 %
    expect(text()).toContain("Ganancia en 8 semanas");
    expect(text()).toContain(n(36000));
    expect(text()).toContain("Promedio por semana");
    expect(text()).toContain(n(4500));
    expect(text()).toContain("2 operaciones por semana");
    expect(text()).toContain("Mejor y peor semana");
    expect(text()).toContain(n(8000));
    expect(text()).toContain(`la más floja: ${n(1000)}`);
    expect(text()).toContain("Margen medio");
    expect(text()).toContain("10 %");
    expect(text()).toContain(`Facturado ${n(360000)}`);
  });

  it("shows the last-6-vs-previous-6 change only when there are enough weeks", async () => {
    await render();
    // last 4 weeks (5..8 thousand = 26000) against the 4 before (1..4 = 10000): +160 %
    expect(text()).toContain("160 %");
    expect(text()).toContain("las últimas 4 semanas frente a las 4 anteriores");
    act(() => root?.unmount());
    container!.remove();
    await render(fetchMock({ weeks: [0] }));
    expect(text()).not.toContain("frente a las");
  });

  it("draws one bar per week in one colour with a dashed average line, and names the chart", async () => {
    await render();
    const figure = container!.querySelector("figure[aria-label]")!;
    expect(figure.getAttribute("aria-label")).toContain("Gráfico de columnas");
    const bars = container!.querySelectorAll(".recharts-bar-rectangle");
    expect(bars).toHaveLength(8);
    const fills = [...container!.querySelectorAll(".recharts-bar-rectangle path")].map((p) => p.getAttribute("fill"));
    expect(new Set(fills)).toEqual(new Set(["var(--chart-profit)"]));
    const dashed = [...container!.querySelectorAll(".recharts-reference-line line")].filter((l) => l.getAttribute("stroke-dasharray"));
    expect(dashed).toHaveLength(1);
    expect(text()).toContain("media 4.5K");
    expect(container!.querySelector(".recharts-legend-wrapper")).toBeNull();
  });

  it("selects the newest week by default, at full opacity, the others lighter", async () => {
    await render();
    expect(selectedPanel().textContent).toContain("SEMANA 8");
    const opacities = [...container!.querySelectorAll(".recharts-bar-rectangle path")].map((p) => p.getAttribute("fill-opacity"));
    expect(opacities).toHaveLength(8);
    expect(opacities[7]).toBe("1");
    expect(opacities.slice(0, 7).every((o) => Number(o) < 1)).toBe(true);
  });

  it("clicking a bar selects that week", async () => {
    await render();
    await click(container!.querySelectorAll(".recharts-bar-rectangle path")[2]!);
    expect(selectedPanel().textContent).toContain("SEMANA 3");
    expect(Number(container!.querySelectorAll(".recharts-bar-rectangle path")[2]!.getAttribute("fill-opacity"))).toBe(1);
  });

  it("describes the selected week: dates, profit with change, billed, invested, margin, ops, best day, top service", async () => {
    await render();
    const panel = selectedPanel().textContent!.replace(/\s+/g, " ");
    expect(panel).toContain("Semana seleccionada");
    expect(panel).toContain("SEMANA 8");
    expect(panel).toContain("20–24 oct"); // entries at the cut minus 6 and minus 2 days
    expect(panel).toContain(n(8000));
    expect(panel).toContain(pctText(100 / 7)); // 8000 over 7000
    expect(panel).toContain("frente a la semana anterior");
    expect(panel).toContain(n(80000)); // billed
    expect(panel).toContain(n(72000)); // invested
    expect(panel).toContain("10 %");
    expect(panel).toMatch(/Operaciones\s*2/);
    expect(panel).toContain("Mejor día");
    expect(panel).toMatch(/Servicio líder/);
    expect(panel).not.toMatch(/cerrada/i);
    expect(panel).not.toContain(".txt");
  });

  it("opens the existing read-only week detail from Ver los registros", async () => {
    await render();
    await click(button("Ver los registros"));
    await flush();
    const view = container!.querySelector("#semanaArchivada") as HTMLElement;
    expect(view).not.toBeNull();
    expect(view.textContent).toContain("SEMANA 8");
    expect(view.querySelector("pre")?.textContent).toBe("texto 7");
    await click(container!.querySelector("#cerrarSemana")!);
    expect(container!.querySelector("#semanaArchivada")).toBeNull();
  });

  it("shows profit by service over the period, highest first, with the share", async () => {
    await render();
    const list = container!.querySelector("[data-testid=cierres-servicios]")!;
    const rows = [...list.querySelectorAll("li")].map((li) => li.textContent!.replace(/\s+/g, " "));
    expect(rows).toHaveLength(2);
    expect(rows[0]).toContain("Zelle");
    expect(rows[0]).toContain(n(21600)); // 60 % of 36000
    expect(rows[0]).toContain("60 %");
    expect(rows[1]).toContain("40 %");
  });

  it("lists six weeks newest first and expands to all of them; clicking a row selects the week", async () => {
    await render();
    const rows = () => [...container!.querySelectorAll("[data-testid=cierres-tabla] tbody tr")] as HTMLElement[];
    expect(rows()).toHaveLength(6);
    expect(rows()[0]!.textContent).toContain("SEMANA 8");
    expect(rows()[0]!.querySelector("button")!.getAttribute("aria-pressed")).toBe("true");
    await click(button("Ver las 8"));
    expect(rows()).toHaveLength(8);
    await click(rows()[7]!.querySelector("button")!);
    expect(selectedPanel().textContent).toContain("SEMANA 1");
    expect(rows()[7]!.querySelector("button")!.getAttribute("aria-pressed")).toBe("true");
    await click(button("Ver menos"));
    expect(rows()).toHaveLength(6);
  });

  it("the table carries ops, billed, profit, margin and the change against the previous week", async () => {
    await render();
    const first = container!.querySelector("[data-testid=cierres-tabla] tbody tr")!.textContent!.replace(/\s+/g, " ");
    for (const part of ["SEMANA 8", "20–24 oct", "2", n(80000), n(8000), "10 %", pctText(100 / 7)]) expect(first).toContain(part);
  });

  it("scrolls the table inside its own box", async () => {
    await render();
    expect(container!.querySelector("[data-testid=cierres-tabla]")!.parentElement!.className).toContain("overflow-x-auto");
  });

  it("has an empty state without archived weeks", async () => {
    await render(fetchMock({ weeks: [] }));
    expect(text()).toContain("Aún no hay semanas archivadas");
    expect(container!.querySelector("figure")).toBeNull();
  });

  it("with a single week: no chart and no change, but the week and its figures", async () => {
    await render(fetchMock({ weeks: [0] }));
    expect(container!.querySelector(".recharts-bar-rectangle")).toBeNull();
    expect(text()).toContain("Con una sola semana");
    expect(selectedPanel().textContent).toContain("SEMANA 1");
    expect(selectedPanel().textContent).not.toContain("frente a la semana anterior");
    expect(text()).not.toContain("la más floja");
  });

  it("keeps a week whose detail cannot be read, with the entry figures left as a dash", async () => {
    await render(fetchMock({ detailStatus: (id) => (id === "w7" ? 500 : 200) }));
    expect(selectedPanel().textContent).toContain("SEMANA 8");
    expect(selectedPanel().textContent!.replace(/\s/g, " ")).toContain(n(8000));
    expect(selectedPanel().textContent).toMatch(/Operaciones\s*—/);
  });

  it("shows an error with a retry when the list cannot be read", async () => {
    await render(fetchMock({ listStatus: 500 }));
    expect(text()).toContain("No se pudieron leer las semanas archivadas.");
    const mock = fetchMock();
    vi.stubGlobal("fetch", mock);
    await click(button("Reintentar"));
    await flush();
    expect(text()).toContain("SEMANA 8");
  });

  it("reads again each time the tab turns active again, and not while it stays hidden", async () => {
    const mock = await render(fetchMock(), true);
    const reads = () => mock.mock.calls.filter(([u]) => u === "/api/calculadora/weeks").length;
    expect(reads()).toBe(1);
    await act(async () => root!.render(ui(false)));
    await flush();
    expect(reads()).toBe(1);
    await act(async () => root!.render(ui(true)));
    await flush();
    expect(reads()).toBe(2);
    // the detail of a closed week never changes: it is not read twice
    expect(mock.mock.calls.filter(([u]) => String(u).startsWith("/api/calculadora/weeks/")).length).toBe(8);
  });

  it("ends with the period close, collapsed until opened, behaviour unchanged inside", async () => {
    await render();
    const toggle = button("Cuadrar un periodo");
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(container!.querySelector("[data-testid=close]")).toBeNull();
    await click(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(container!.querySelector("[data-testid=close]")).not.toBeNull();
    const all = [...container!.querySelectorAll("h2, [data-testid=close]")];
    expect(all[all.length - 1]).toBe(container!.querySelector("[data-testid=close]"));
  });

  it("shows no emoji", async () => {
    await render();
    expect(container!.textContent).not.toMatch(/\p{Extended_Pictographic}/u);
  });
});
