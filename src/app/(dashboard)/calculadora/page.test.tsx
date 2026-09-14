// @vitest-environment jsdom
// Component-level coverage for the slice-1 global rate inputs: they render
// with the expected Spanish labels, hydrate from the GET document (including
// accounts that predate the new columns), and feed the existing debounced
// POST save alongside rawText/periodo/tarifa. The legacy manual textarea
// formulas (web-calculator.ts) are untouched and are not re-tested here.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import CalculadoraPage from "./page";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// This Node/jsdom combination only exposes `localStorage` behind a CLI flag
// vitest doesn't set, so the page's persistence fallback needs an in-memory
// stand-in here rather than the real thing.
class MemoryStorage implements Storage {
  private store = new Map<string, string>();
  get length() { return this.store.size; }
  clear() { this.store.clear(); }
  getItem(key: string) { return this.store.has(key) ? this.store.get(key)! : null; }
  key(index: number) { return [...this.store.keys()][index] ?? null; }
  removeItem(key: string) { this.store.delete(key); }
  setItem(key: string, value: string) { this.store.set(key, String(value)); }
}

function flush() {
  return act(async () => { await Promise.resolve(); await Promise.resolve(); });
}

function inputValue(node: HTMLElement, id: string) {
  return (node.querySelector(`#${id}`) as HTMLInputElement).value;
}

function setInputValue(node: HTMLElement, id: string, value: string) {
  const input = node.querySelector(`#${id}`) as HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

beforeEach(() => {
  vi.stubGlobal("localStorage", new MemoryStorage());
});

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.clearAllMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("calculator global rate inputs (slice 1)", () => {
  it("renders the four Spanish-labeled global rate inputs", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      rawText: "", periodo: "", tarifa: 3, compraUsdtGyd: null, ventaUsdtGyd: null, ventaUsdtCup: null,
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () => root.render(<CalculadoraPage />));
    await flush();

    expect(node.querySelector('label[for="tarifaCupGlobal"]')?.textContent).toBe("Tarifa CUP global");
    expect(node.querySelector('label[for="compraUsdtGyd"]')?.textContent).toBe("Compra USDT (GYD)");
    expect(node.querySelector('label[for="ventaUsdtGyd"]')?.textContent).toBe("Venta USDT/Zelle (GYD)");
    expect(node.querySelector('label[for="ventaUsdtCup"]')?.textContent).toBe("Venta USDT (CUP)");
    await act(async () => root.unmount());
  });

  it("hydrates from a document that predates the USDT rate columns (nulls -> empty inputs, tarifa still shown)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      rawText: "• Fran 50k CUP (235/980)", periodo: "SEMANA 1", tarifa: 3, compraUsdtGyd: null, ventaUsdtGyd: null, ventaUsdtCup: null,
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () => root.render(<CalculadoraPage />));
    await flush();

    expect(inputValue(node, "tarifaCupGlobal")).toBe("3");
    expect(inputValue(node, "compraUsdtGyd")).toBe("");
    expect(inputValue(node, "ventaUsdtGyd")).toBe("");
    expect(inputValue(node, "ventaUsdtCup")).toBe("");
    await act(async () => root.unmount());
  });

  it("hydrates saved USDT rates and includes them in the debounced save", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      rawText: "", periodo: "", tarifa: 3, compraUsdtGyd: 235, ventaUsdtGyd: 260, ventaUsdtCup: 975,
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () => root.render(<CalculadoraPage />));
    await flush();

    expect(inputValue(node, "compraUsdtGyd")).toBe("235");
    expect(inputValue(node, "ventaUsdtGyd")).toBe("260");
    expect(inputValue(node, "ventaUsdtCup")).toBe("975");

    fetchMock.mockClear();
    act(() => setInputValue(node, "ventaUsdtCup", "980"));
    await act(async () => { await vi.advanceTimersByTimeAsync(600); });

    expect(fetchMock).toHaveBeenCalledWith("/api/calculadora", expect.objectContaining({ method: "POST" }));
    const body = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string);
    expect(body).toMatchObject({ tarifa: 3, compraUsdtGyd: 235, ventaUsdtGyd: 260, ventaUsdtCup: 980 });
    await act(async () => root.unmount());
  });

  it("sends null for a blanked optional rate instead of a placeholder default", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      rawText: "", periodo: "", tarifa: 3, compraUsdtGyd: 235, ventaUsdtGyd: null, ventaUsdtCup: null,
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () => root.render(<CalculadoraPage />));
    await flush();

    fetchMock.mockClear();
    act(() => setInputValue(node, "compraUsdtGyd", ""));
    await act(async () => { await vi.advanceTimersByTimeAsync(600); });

    const body = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string);
    expect(body).toMatchObject({ compraUsdtGyd: null, ventaUsdtGyd: null, ventaUsdtCup: null });
    await act(async () => root.unmount());
  });

  it("shows chat operations read-only and combines only completed snapshots", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      rawText: "• Manual 1 USDT (240/260)",
      periodo: "SEMANA 1",
      tarifa: 3,
      compraUsdtGyd: 240,
      ventaUsdtGyd: 260,
      ventaUsdtCup: 975,
      chatOperations: {
        entries: [
          {
            id: "entry-completed",
            operationId: "op-completed",
            status: "completed",
            service: "ZELLE",
            customerName: "Raúl",
            amount: 100,
            amountCurrency: "USD",
            entryDate: "2026-09-12",
            facturadoGyd: 26000,
            invertidoGyd: 24000,
            retornoGyd: 2000,
            missingRates: [],
          },
          {
            id: "entry-pending",
            operationId: "op-pending",
            status: "verified_pending",
            service: "CUP",
            customerName: "Bladimir",
            amount: 30000,
            amountCurrency: "CUP",
            entryDate: "2026-09-12",
            facturadoGyd: null,
            invertidoGyd: null,
            retornoGyd: null,
            missingRates: ["usdtSellCup"],
          },
        ],
      },
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () => root.render(<CalculadoraPage />));
    await flush();

    expect(node.textContent).toContain("Operaciones del chat (solo lectura)");
    expect(node.textContent).toContain("Completada");
    expect(node.textContent).toContain("Pendiente: usdtSellCup");
    expect(node.textContent).toContain("26260.00");
    expect(node.textContent).toContain("24240.00");
    expect(node.textContent).toContain("2020.00");
    await act(async () => root.unmount());
  });

  it("shows the canonical service as the amount suffix instead of the internal amount currency", async () => {
    // The Zelle operation settles in USD internally (amountCurrency), but the
    // owner wants the visible amount suffix to be unambiguous: the canonical
    // service (ZELLE), never a currency code like USD.
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      rawText: "",
      periodo: "SEMANA 1",
      tarifa: 3,
      compraUsdtGyd: null,
      ventaUsdtGyd: null,
      ventaUsdtCup: null,
      chatOperations: {
        entries: [
          {
            id: "entry-zelle",
            operationId: "op-zelle",
            status: "completed",
            service: "ZELLE",
            customerName: "Raúl",
            amount: 100,
            amountCurrency: "USD",
            entryDate: "2026-09-12",
            facturadoGyd: 26000,
            invertidoGyd: 24000,
            retornoGyd: 2000,
            missingRates: [],
          },
        ],
      },
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () => root.render(<CalculadoraPage />));
    await flush();

    const montoCell = node.querySelector('td[data-label="Monto"]');
    expect(montoCell?.textContent).toBe("100 ZELLE");
    expect(node.textContent).not.toContain("100 USD");
    await act(async () => root.unmount());
  });
});
