// @vitest-environment jsdom
// The Semana overview: KPI cards, profit by day, the "Hoy" box, profit by service, top clients and the rates line,
// all drawn from the entries the page already holds. The figures themselves are tested in semana-overview.test.ts.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, describe, expect, it, vi } from "vitest";

import esMessages from "../../../messages/es.json";
import { num } from "@/lib/finanzas/number-format";
import type { OverviewEntry, PreviousWeekInput } from "@/lib/finanzas/semana-overview";
import { SemanaOverviewView, type SemanaOverviewViewProps } from "./semana-overview";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// Wednesday 28 Oct 2026 in Guyana; the open week was cut on Monday 26.
const NOW = new Date("2026-10-28T15:00:00Z");
const CUT = "2026-10-26T12:00:00Z";
// Figures use comma thousands and dot decimals, like the rest of the Finanzas mockups.
const n = (value: number) => num(value);

let seq = 0;
function entry(overrides: Partial<OverviewEntry> = {}): OverviewEntry {
  seq += 1;
  return {
    id: `e${seq}`,
    entryDate: "2026-10-27",
    status: "completed",
    service: "ZELLE",
    customerName: "Ana",
    facturadoGyd: 100000,
    invertidoGyd: 90000,
    retornoGyd: 10000,
    usdtBuyGyd: 250,
    missingRates: [],
    ...overrides,
  };
}

const ENTRIES: OverviewEntry[] = [
  entry({ entryDate: "2026-10-26", service: "ZELLE", customerName: "Ana", facturadoGyd: 100000, invertidoGyd: 90000, retornoGyd: 10000 }),
  entry({ entryDate: "2026-10-27", service: "CUP", customerName: "Bruno", facturadoGyd: 50000, invertidoGyd: 45000, retornoGyd: 5000, usdtBuyGyd: 250 }),
  entry({ entryDate: "2026-10-28", service: "CUP", customerName: "Bruno", facturadoGyd: 50000, invertidoGyd: 45000, retornoGyd: 5000 }),
  entry({ entryDate: "2026-10-28", status: "verified_pending", service: "MLC", customerName: "Carla", facturadoGyd: null, invertidoGyd: null, retornoGyd: null, missingRates: ["usdt_buy_gyd"] }),
  entry({ entryDate: "2026-10-28", status: "void", customerName: "Dora", retornoGyd: 999999 }),
];

const PREVIOUS: PreviousWeekInput = {
  startDay: "2026-10-19",
  entries: [{ entryDate: "2026-10-20", facturadoGyd: 200000, retornoGyd: 16000 }],
};

let container: HTMLDivElement | null = null;
let root: ReturnType<typeof createRoot> | null = null;

function render(overrides: Partial<SemanaOverviewViewProps> = {}) {
  const props: SemanaOverviewViewProps = {
    entries: ENTRIES,
    cutAt: CUT,
    previous: PREVIOUS,
    now: NOW,
    ready: true,
    onRegister: vi.fn(),
    onCloseWeek: vi.fn(),
    onPickService: vi.fn(),
    onPickClient: vi.fn(),
    onShowPending: vi.fn(),
    activeService: null,
    activeClient: null,
    ...overrides,
  };
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  act(() => {
    root!.render(
      <NextIntlClientProvider locale="es" messages={esMessages}>
        <SemanaOverviewView {...props} />
      </NextIntlClientProvider>,
    );
  });
  return props;
}

const text = () => container!.textContent!.replace(/\s+/g, " ");
const button = (label: string) => [...container!.querySelectorAll("button")].find((b) => b.textContent === label)!;

afterEach(() => {
  act(() => root?.unmount());
  container?.remove();
  container = null;
  root = null;
});

describe("SemanaOverviewView", () => {
  it("says when the open week started, in Guyana days", () => {
    render();
    expect(text()).toContain("Semana abierta · desde el corte del lunes 26 oct · hora de Guyana");
  });

  it("shows the four KPI cards from the completed entries only", () => {
    render();
    expect(text()).toContain("Ganancia de la semana");
    expect(text()).toContain(n(20000)); // 10000 + 5000 + 5000, never the void 999999
    expect(text()).toContain(n(200000)); // facturado
    expect(text()).toContain("3 operaciones");
    expect(text()).toContain(n(180000)); // invertido
    expect(text()).toContain("10 %"); // 20000 / 200000
    expect(text()).toContain(`Ticket medio ${n(200000 / 3)}`);
  });

  it("shows USDT bought and the average cost when entries carry a rate", () => {
    render();
    // (90000 + 45000 + 45000) / 250 = 720 USDT, average cost 250
    expect(text()).toContain("720 USDT · costo medio 250");
  });

  it("omits the USDT line when no entry has a rate", () => {
    render({ entries: ENTRIES.map((e) => ({ ...e, usdtBuyGyd: null })) });
    expect(text()).not.toContain("USDT · costo medio");
  });

  it("compares the profit with last week at the same point, with an arrow and words", () => {
    render();
    // 20000 now vs 16000 then = +25 %
    expect(text()).toContain("25 %");
    expect(text()).toContain("frente a la semana pasada a la misma altura");
    expect(container!.textContent).toContain("▲");
    expect(text()).toContain("Sube");
  });

  it("says so when there is no previous week", () => {
    render({ previous: null });
    expect(text()).toContain("sin semana anterior para comparar");
    expect(container!.textContent).not.toContain("▲");
  });

  it("fills the Hoy box and warns about the lines that are missing a rate", () => {
    render();
    const hoy = container!.querySelector('[data-testid="semana-hoy"]')!.textContent!.replace(/\s+/g, " ");
    expect(hoy).toMatch(/Operaciones completadas\s*1(?!\d)/);
    expect(hoy).toContain(`Facturado hoy${n(50000)} GYD`);
    expect(hoy).toContain(`Ganancia hoy${n(5000)} GYD`);
    expect(hoy).toContain("1 sin tasa · no cuentan aún");
  });

  it("counts the other pending lines apart from the ones missing a rate, each with a link to see them", () => {
    const pending = entry({ entryDate: "2026-10-28", status: "verified_pending", service: "COMBO", customerName: "Eva", missingRates: ["combo_cost"], facturadoGyd: null, invertidoGyd: null, retornoGyd: null });
    const props = render({ entries: [...ENTRIES, pending, { ...pending, id: "p2" }] });
    const hoy = container!.querySelector('[data-testid="semana-hoy"]')!;
    expect(hoy.textContent).toContain("1 sin tasa");
    expect(hoy.textContent).toContain("2 pendientes");
    act(() => (hoy.querySelector('[data-show="sinTasa"]') as HTMLElement).click());
    act(() => (hoy.querySelector('[data-show="pending"]') as HTMLElement).click());
    expect(props.onShowPending).toHaveBeenNthCalledWith(1, "sinTasa");
    expect(props.onShowPending).toHaveBeenNthCalledWith(2, "pending");
  });

  it("turns each service and each client into a button that filters the records table", () => {
    const props = render({ activeService: "CUP", activeClient: null });
    const services = [...container!.querySelectorAll('[data-testid="semana-servicios"] button')] as HTMLButtonElement[];
    expect(services.map((b) => b.getAttribute("aria-pressed"))).toEqual(["true", "false"]);
    act(() => services[1]!.click());
    expect(props.onPickService).toHaveBeenCalledWith("ZELLE");
    const clients = [...container!.querySelectorAll('[data-testid="semana-clientes"] button')] as HTMLButtonElement[];
    act(() => clients[0]!.click());
    expect(props.onPickClient).toHaveBeenCalledWith("Ana");
  });

  it("shows no warning when every line is complete", () => {
    render({ entries: ENTRIES.filter((e) => e.status === "completed") });
    expect(text()).not.toContain("sin tasa");
  });

  it("lists profit by service sorted with its margin, and the top clients", () => {
    render();
    const services = container!.querySelector('[data-testid="semana-servicios"]')!;
    const rows = [...services.querySelectorAll("li")].map((li) => li.textContent!.replace(/\s+/g, " "));
    expect(rows).toHaveLength(2);
    expect(rows[0]).toContain(n(10000)); // CUP and ZELLE tie at 10000; ties break by key, CUP first
    expect(rows[0]).toContain("10 %");
    const clients = [...container!.querySelectorAll('[data-testid="semana-clientes"] li')].map((li) => li.textContent!);
    expect(clients).toHaveLength(2);
    expect(clients[0]).toContain("Ana");
    expect(clients[1]).toContain("Bruno");
  });

  it("gives the day chart a label and a table twin", () => {
    render();
    expect(container!.querySelector('figure[aria-label^="Gráfico de columnas"]')).not.toBeNull();
    const rows = container!.querySelectorAll('[data-testid="semana-dias"] tbody tr');
    expect(rows).toHaveLength(6);
  });

  it("charts the days of the OPEN week, not the calendar week, and says which are in progress or not reached yet", () => {
    // Cut on Wednesday 21: eight days to Wednesday 28.
    render({ cutAt: "2026-10-21T12:00:00Z", entries: [entry({ entryDate: "2026-10-21", retornoGyd: 1200 }), ...ENTRIES] });
    const twin = [...container!.querySelectorAll('[data-testid="semana-dias"] tbody tr')].map((r) => r.firstElementChild!.textContent);
    expect(twin).toHaveLength(8);
    expect(twin[0]).toBe("Mié 21");
    expect(twin[7]).toBe("Mié 28 · hoy");
    const chart = container!.querySelector('[data-testid="semana-dia-card"]')!.textContent!;
    expect(chart).toContain("en curso");
  });

  it("puts a value label on every bar, marks today as in progress and the days not reached as 'aún no', with no y axis", () => {
    render();
    const labels = [...container!.querySelectorAll('[data-testid="semana-dia-card"] svg text')].map((t) => t.textContent);
    expect(labels).toContain(n(10000)); // Monday
    expect(labels).toContain(n(5000)); // Tuesday and Wednesday
    expect(labels.filter((l) => l === "en curso")).toHaveLength(1);
    expect(labels.filter((l) => l === "aún no")).toHaveLength(3);
    expect(container!.querySelector('[data-testid="semana-dia-card"] .recharts-yAxis')).toBeNull();
  });

  it("draws the day chart in its own card, apart from the Hoy box", () => {
    render();
    const card = container!.querySelector('[data-testid="semana-dia-card"]')!;
    expect(card.querySelector('[data-testid="semana-hoy"]')).toBeNull();
    expect(card.textContent).toContain("Ganancia por día");
  });

  it("writes figures with comma thousands and dot decimals", () => {
    render({
      entries: [entry({ entryDate: "2026-10-28", facturadoGyd: 356090, invertidoGyd: 320481, retornoGyd: 35609, usdtBuyGyd: 239.5 })],
    });
    expect(text()).toContain("35,609");
    expect(text()).toContain("356,090");
    expect(text()).toContain("239.5");
    expect(text()).not.toMatch(/\d[\u00a0\u202f ]\d{3}/);
  });

  it("says 'Cifras en GYD' once and keeps the unit off the cards", () => {
    render();
    expect(text().match(/Cifras en GYD/g)).toHaveLength(1);
    const cards = container!.querySelectorAll('[data-testid="semana-kpi"]');
    expect(cards).toHaveLength(4);
    cards.forEach((card) => expect(card.textContent).not.toContain("GYD"));
  });

  it("gives the profit card the same size as the others, in the profit colour", () => {
    render();
    const values = [...container!.querySelectorAll('[data-testid="semana-kpi"] [data-kpi-value]')] as HTMLElement[];
    expect(values[0].className).toContain("text-money-profit");
    expect(values[1].className).not.toContain("text-money-profit");
    const size = (el: HTMLElement) => el.className.split(" ").filter((c) => c.startsWith("text-") && /xl|lg/.test(c)).join(" ");
    expect(size(values[0])).toBe(size(values[1]));
  });

  it("shows the incomplete-lines warning on a neutral ground with an amber dot, never brown text", () => {
    render();
    const warning = container!.querySelector('[data-testid="semana-hoy"] [data-warning]') as HTMLElement;
    expect(warning.className).toContain("bg-muted");
    expect(warning.className).toContain("text-foreground");
    expect(warning.className).not.toMatch(/status-attention|amber|yellow|orange|brown/);
    expect(warning.querySelector("[data-warning-dot]")!.className).toContain("bg-amber-500");
  });

  it("dates the Hoy box", () => {
    render();
    expect(container!.querySelector('[data-testid="semana-hoy"]')!.textContent).toContain("miércoles 28 oct");
  });

  it("calls the handlers from the header actions and the rates link", () => {
    const props = render();
    act(() => button("+ Registrar línea").click());
    act(() => button("Revisar y cerrar semana").click());
    expect(props.onRegister).toHaveBeenCalledTimes(1);
    expect(props.onCloseWeek).toHaveBeenCalledTimes(1);
  });

  it("no longer carries its own rates line: the rates live in the Tasas actuales card", () => {
    render();
    expect(text()).not.toContain("Tarifas en vigor");
  });

  it("shows a friendly empty state, not zeros, when the week has no operations", () => {
    render({ entries: [], cutAt: null, previous: null });
    expect(text()).toContain("Aún no hay operaciones en la semana abierta");
    expect(text()).not.toContain("Ganancia de la semana");
    expect(button("+ Registrar línea")).toBeDefined();
  });

  it("holds the place while the page is still loading", () => {
    render({ ready: false });
    expect(container!.querySelector('[aria-busy="true"]')).not.toBeNull();
    expect(text()).not.toContain("Aún no hay operaciones");
  });
});
