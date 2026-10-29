// @vitest-environment jsdom
// "Tasas actuales": every global rate in four equal cards, edited in place. The save itself (POST /api/calculator/rates)
// stays in the page; these tests drive the card with plain props.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, describe, expect, it, vi } from "vitest";

import esMessages from "../../../messages/es.json";
import type { CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { RATE_FIELDS, RATE_GROUPS, type RateGroup } from "@/lib/finanzas/rate-groups";
import { RatesCard, type RatesCardProps } from "./rates-card";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const RATES = {
  id: "v1", cupGlobalRate: 980, usdtBuyGyd: 242, usdtSellGyd: 260, usdtSellCup: 470, zelleSellGyd: 235, zelleSellGyd1000: 232,
  zelleSellGyd2000: 230, efectivoUsdGyd: 250, recargaCostoUsdt: 4.6, saldoCostoUsdt: 1.25, recargaCostoUsdt500: 3.9,
} as unknown as CalculatorRates;

let container: HTMLDivElement | null = null;
let root: ReturnType<typeof createRoot> | null = null;

function render(overrides: Partial<RatesCardProps> = {}) {
  const props: RatesCardProps = {
    rates: RATES,
    fields: RATE_FIELDS,
    groups: RATE_GROUPS,
    arq: null,
    editing: null,
    draft: "",
    locked: false,
    saving: false,
    message: null,
    onStartEdit: vi.fn(),
    onDraftChange: vi.fn(),
    onSave: vi.fn(),
    onCancel: vi.fn(),
    ...overrides,
  };
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const ui = (p: RatesCardProps) => (
    <NextIntlClientProvider locale="es" messages={esMessages}>
      <RatesCard {...p} />
    </NextIntlClientProvider>
  );
  act(() => root!.render(ui(props)));
  return { props, rerender: (next: Partial<RatesCardProps>) => act(() => root!.render(ui({ ...props, ...next }))) };
}

const text = () => container!.textContent!.replace(/\s+/g, " ");
const group = (title: string) => [...container!.querySelectorAll('[data-testid="tasas-grupo"]')].find((g) => g.querySelector("h3")!.textContent === title) as HTMLElement;
const row = (key: string) => container!.querySelector(`[data-rate="${key}"]`) as HTMLElement;

afterEach(() => {
  act(() => root?.unmount());
  container?.remove();
  container = null;
  root = null;
});

describe("RatesCard", () => {
  it("shows every rate of RATE_FIELDS inside one of four groups, with its value and unit", () => {
    render();
    expect(container!.querySelectorAll('[data-testid="tasas-grupo"]')).toHaveLength(4);
    for (const field of RATE_FIELDS) expect(row(field.key), field.key).not.toBeNull();
    expect(group("USDT").textContent).toContain("Compra242GYD");
    expect(group("USDT").textContent).toContain("Venta en CUP470CUP");
    expect(group("Zelle · GYD por dólar").textContent).toContain("Desde 1,000 USD232GYD");
    expect(group("Recargas y saldo · costo").textContent).toContain("Recarga desde 6004.6USDT");
    expect(group("CUP, efectivo y México").textContent).toContain("Tarifa CUP global980");
  });

  it("notes that the USDT sale rate also prices Clásica, Tropical and México", () => {
    render();
    expect(row("usdt_sell_gyd").textContent).toContain("también Clásica, Tropical y México");
  });

  it("shows a dash for a rate that is not set yet", () => {
    render({ rates: { ...RATES, efectivoUsdGyd: null } as unknown as CalculatorRates });
    expect(row("efectivo_usd_gyd").textContent).toContain("—");
    render({ rates: null });
    expect(container!.textContent).toContain("—");
  });

  it("lays the groups out as wrapping equal cards that size themselves by container width", () => {
    render();
    const wrap = container!.querySelector('[data-testid="tasas-grupos"]') as HTMLElement;
    expect(wrap.className).toContain("flex-wrap");
    for (const card of container!.querySelectorAll('[data-testid="tasas-grupo"]')) {
      expect(card.className).toContain("@container");
      expect(card.className).toContain("flex-1");
    }
  });

  it("draws a rate added to the group config in its group, with no layout change", () => {
    const fields = [...RATE_FIELDS, { key: "nueva_tasa", label: "Nueva tasa", field: "nuevaTasa" }] as unknown as typeof RATE_FIELDS;
    const groups: RateGroup[] = RATE_GROUPS.map((g) =>
      g.id === "usdt" ? { ...g, rates: [...g.rates, { key: "nueva_tasa" as never, label: "Nueva tasa", unit: "GYD" }] } : g,
    );
    render({ fields, groups, rates: { ...RATES, nuevaTasa: 12.5 } as unknown as CalculatorRates });
    expect(container!.querySelectorAll('[data-testid="tasas-grupo"]')).toHaveLength(4);
    expect(group("USDT").textContent).toContain("Nueva tasa12.5GYD");
  });

  it("never drops a rate that no group lists: it goes to a last group", () => {
    const fields = [...RATE_FIELDS, { key: "otra_tasa", label: "Otra tasa", field: "otraTasa" }] as unknown as typeof RATE_FIELDS;
    render({ fields, rates: { ...RATES, otraTasa: 7 } as unknown as CalculatorRates });
    const groups = container!.querySelectorAll('[data-testid="tasas-grupo"]');
    expect(groups).toHaveLength(5);
    expect(groups[4].textContent).toContain("Otra tasa7");
  });

  it("starts editing when a rate is pressed", () => {
    const { props } = render();
    act(() => (row("usdt_buy_gyd").querySelector("button") as HTMLButtonElement).click());
    expect(props.onStartEdit).toHaveBeenCalledWith("usdt_buy_gyd");
  });

  it("edits in place: an input with the draft, Enter saves, Escape cancels, Guardar and Cancelar work", () => {
    const { props } = render({ editing: "usdt_buy_gyd", draft: "243" });
    const input = row("usdt_buy_gyd").querySelector("input") as HTMLInputElement;
    expect(input.value).toBe("243");
    expect(input.getAttribute("aria-label")).toBe("Nuevo valor de Compra");
    act(() => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
    expect(props.onSave).toHaveBeenCalledTimes(1);
    act(() => input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(props.onCancel).toHaveBeenCalledTimes(1);
    act(() => (container!.querySelector('button[aria-label="Guardar"]') as HTMLButtonElement).click());
    act(() => (container!.querySelector('button[aria-label="Cancelar"]') as HTMLButtonElement).click());
    expect(props.onSave).toHaveBeenCalledTimes(2);
    expect(props.onCancel).toHaveBeenCalledTimes(2);
  });

  it("passes what is typed to the page", () => {
    const { props } = render({ editing: "usdt_buy_gyd", draft: "243" });
    const input = row("usdt_buy_gyd").querySelector("input") as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    act(() => {
      setter.call(input, "250");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(props.onDraftChange).toHaveBeenCalledWith("250");
  });

  it("disables the editor while saving and every rate once the page is locked, keeping the message", () => {
    render({ editing: "usdt_buy_gyd", draft: "243", saving: true });
    expect((row("usdt_buy_gyd").querySelector("input") as HTMLInputElement).disabled).toBe(true);
    expect((container!.querySelector('button[aria-label="Guardar"]') as HTMLButtonElement).disabled).toBe(true);
    act(() => root!.unmount());
    container!.remove();
    render({ locked: true, message: { text: "Solo un administrador puede modificar las tasas.", kind: "error" } });
    expect((row("usdt_buy_gyd").querySelector("button") as HTMLButtonElement).disabled).toBe(true);
    expect(container!.querySelector('[role="status"]')!.textContent).toBe("Solo un administrador puede modificar las tasas.");
  });

  it("shows the ARQ rate as automatic and not editable, with its age", () => {
    render({ arq: { value: 18.42, note: "ask 18.5 · hace 5 min", warn: false, ageLabel: "hace 5 min" } });
    const arq = container!.querySelector('[data-testid="tasa-arq"]') as HTMLElement;
    expect(arq.textContent).toContain("USD → MXN");
    expect(arq.textContent).toContain("auto, hace 5 min");
    expect(arq.textContent).toContain("18.42");
    expect(arq.querySelector("button")).toBeNull();
    expect(group("CUP, efectivo y México").contains(arq)).toBe(true);
  });

  it("marks a stale ARQ rate on a neutral ground with an amber dot, not in coloured text", () => {
    render({ arq: { value: 18.42, note: "sin actualizar desde hace 3 h", warn: true, ageLabel: "hace 3 h" } });
    const note = container!.querySelector('[data-testid="tasa-arq"] [data-warning]') as HTMLElement;
    expect(note.textContent).toContain("sin actualizar desde hace 3 h");
    expect(note.className).toContain("bg-muted");
    expect(note.className).not.toMatch(/status-attention|amber|brown|yellow/);
    expect(note.querySelector("[data-warning-dot]")!.className).toContain("bg-amber-500");
  });

  it("renders no ARQ row without a rate", () => {
    render();
    expect(container!.querySelector('[data-testid="tasa-arq"]')).toBeNull();
    expect(text()).toContain("Tasas actuales");
  });
});
