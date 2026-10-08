// @vitest-environment jsdom
// Spec: odd/tasks/finanzas-profit-ring.md (P2). Edge cases of the profit-by-service ring.

import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import { FinancialCloseProfitRing } from "./financial-close-profit-ring";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

const svc = (service: string, retornoGyd: number) => ({
  service,
  operations: 1,
  facturadoGyd: 0,
  invertidoGyd: 0,
  retornoGyd,
});

let container: HTMLDivElement;
let root: Root;

function render(byService: ReturnType<typeof svc>[]) {
  act(() => {
    root.render(<FinancialCloseProfitRing byService={byService} />);
  });
}

const slices = () => container.querySelectorAll("[data-testid='ring-slice']");
const rows = () => Array.from(container.querySelectorAll("[data-testid='ring-row']")) as HTMLElement[];
const row = (service: string) => rows().find((r) => r.dataset.service === service)!;

beforeEach(() => {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});
afterEach(() => {
  act(() => root.unmount());
  container.remove();
});

describe("FinancialCloseProfitRing", () => {
  it("shows an empty state and no ring without operations", () => {
    render([]);
    expect(container.textContent).toContain(en.Resumen.cierre.gananciaServicio.title);
    expect(container.textContent).toContain(en.Resumen.cierre.sinDatos);
    expect(container.querySelector("svg")).toBeNull();
    expect(container.textContent).not.toContain("NaN");
  });

  it("draws one slice per profitable service, sorted by profit, with name, GYD and share", () => {
    render([svc("CUP", 300), svc("ZELLE", 500), svc("USDT", 200)]);
    expect(slices()).toHaveLength(3);
    expect(rows().map((r) => r.dataset.service)).toEqual(["ZELLE", "CUP", "USDT"]);
    expect(row("ZELLE").textContent).toContain("ZELLE");
    expect(row("ZELLE").textContent).toContain("500 GYD");
    expect(row("ZELLE").textContent).toContain("50%");
    expect(row("CUP").textContent).toContain("30%");
  });

  it("shows the total profit in the ring centre, formatted with the money format", () => {
    render([svc("ZELLE", 1157712.4)]);
    expect(container.querySelector("svg")!.textContent).toContain("1\u202f157\u202f712,4 GYD");
  });

  it("draws a full ring for a single service", () => {
    render([svc("ZELLE", 250)]);
    expect(slices()).toHaveLength(1);
    expect(row("ZELLE").textContent).toContain("100%");
    const d = slices()[0].getAttribute("d")!;
    expect(d).not.toContain("NaN");
  });

  it("lists a zero-profit service with 0 and no slice", () => {
    render([svc("ZELLE", 100), svc("CUP", 0)]);
    expect(slices()).toHaveLength(1);
    expect(row("CUP").textContent).toContain("0 GYD");
    expect(row("CUP").textContent).toContain("0%");
  });

  it("lists a negative service with its figure and a dash, outside the ring and the base", () => {
    render([svc("ZELLE", 300), svc("CUP", 100), svc("USDT", -50)]);
    expect(slices()).toHaveLength(2);
    expect(row("USDT").textContent).toContain("-50 GYD");
    expect(row("USDT").textContent).toContain("—");
    expect(row("ZELLE").textContent).toContain("75%");
  });

  it("shows only the legend when the total profit is not positive", () => {
    render([svc("ZELLE", 100), svc("CUP", -300)]);
    expect(container.querySelector("svg")).toBeNull();
    expect(rows()).toHaveLength(2);
    expect(row("CUP").textContent).toContain("-300 GYD");
    expect(container.textContent).not.toContain("NaN");
  });

  it("names the chart for assistive technology", () => {
    render([svc("ZELLE", 100)]);
    const svg = container.querySelector("svg")!;
    expect(svg.getAttribute("role")).toBe("img");
    expect(svg.getAttribute("aria-label")).toContain(en.Resumen.cierre.gananciaServicio.title);
  });

  it("renders readable labels for the dispatch service", () => {
    render([svc("DIRECTO", 100)]);
    expect(row("DIRECTO").textContent).toContain("Trámites / Combos / Servicios");
  });
});
