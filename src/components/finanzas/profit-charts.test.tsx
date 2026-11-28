// @vitest-environment jsdom
// The profit-by-service chart of Finanzas > Cierres: they render from the series, stay out when there is nothing to
// compare, are named for assistive tech and their tooltips carry the figures the brief asks for.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
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
import { ProfitByServiceChart, ServiceTooltip } from "./profit-charts";

const plain = (n: number) => formatNumber(n, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const agg = (operations: number, facturadoGyd: number, invertidoGyd: number, retornoGyd: number) => ({ operations, facturadoGyd, invertidoGyd, retornoGyd });
const BY_SERVICE: FinancialClose["byService"] = [
  { service: "CUP", ...agg(1, 1000, 700, 300) },
  { service: "ZELLE", ...agg(2, 2000, 1500, 500) },
];
async function mount(element: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(element));
  return node;
}

afterEach(() => document.body.replaceChildren());

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

describe("tooltips", () => {
  const text = async (el: React.ReactElement) => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    await act(async () => createRoot(node).render(el));
    return node.textContent;
  };

  it("service: facturado, invertido, retorno and margen", async () => {
    const out = await text(<ServiceTooltip active payload={[{ payload: { service: "ZELLE", facturado: 2000, invertido: 1500, retorno: 500, margin: "25.0", operations: 2 } }]} />);
    for (const part of ["zelle", fmtGyd(2000), fmtGyd(1500), fmtGyd(500), "Margen 25.0%"]) expect(out).toContain(part);
  });

  it("render nothing when inactive", async () => {
    expect(await text(<ServiceTooltip active={false} payload={[]} />)).toBe("");
  });
});
