// @vitest-environment jsdom
// Component-level coverage for the calculator page's rate handling after
// slice 9 moved the four global rates into the append-only
// calculator_rate_versions table:
//  - the rate inputs hydrate from GET /api/calculator/rates (never a fake
//    default like "3.0"), and its `id` is kept as the concurrency token;
//  - rates no longer ride the debounced POST /api/calculadora save;
//  - an explicit "Guardar tasas" button POSTs only the filled-in rates
//    (snake_case) plus expectedVersionId to POST /api/calculator/rates, and
//    reacts to 403 (admin-only, disables editing)/409 (stale, reload)/other
//    failures with Spanish messages;
//  - a pending banner lists chat entries stuck on verified_pending and the
//    rates they are missing.
// The legacy manual textarea formulas (web-calculator.ts) are untouched and
// are not re-tested here.

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
  return act(async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); });
}

function inputValue(node: HTMLElement, id: string) {
  return (node.querySelector(`#${id}`) as HTMLInputElement).value;
}

function isInputDisabled(node: HTMLElement, id: string) {
  return (node.querySelector(`#${id}`) as HTMLInputElement).disabled;
}

function setInputValue(node: HTMLElement, id: string, value: string) {
  const input = node.querySelector(`#${id}`) as HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}

type RatesPostResult = { status: number; body?: unknown };

/** Routes the page's fetch calls by URL + method instead of a single blanket
 * mock, since the page now talks to two GET endpoints on hydration
 * (/api/calculadora and /api/calculator/rates) plus two POST endpoints
 * (document autosave and the explicit rate save). */
function createFetchMock(config: {
  calculadoraGet?: unknown;
  ratesGet?: { rates: unknown };
  calculadoraPost?: unknown;
  ratesPost?: (body: { rates: Record<string, unknown>; expectedVersionId?: string }) => RatesPostResult;
}) {
  return vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = init?.method ?? "GET";
    if (url.startsWith("/api/calculadora") && method === "GET") {
      return Promise.resolve(jsonResponse(config.calculadoraGet ?? { rawText: "", periodo: "" }));
    }
    if (url === "/api/calculator/rates" && method === "GET") {
      return Promise.resolve(jsonResponse(config.ratesGet ?? { rates: null }));
    }
    if (url === "/api/calculadora" && method === "POST") {
      return Promise.resolve(jsonResponse(config.calculadoraPost ?? { rawText: "", periodo: "" }));
    }
    if (url === "/api/calculator/rates" && method === "POST") {
      const body = JSON.parse((init?.body as string) ?? "{}");
      const result = config.ratesPost
        ? config.ratesPost(body)
        : { status: 200, body: { rates: { id: "rate-1", ...body.rates } } };
      return Promise.resolve(jsonResponse(result.body ?? {}, result.status));
    }
    return Promise.reject(new Error(`Unhandled fetch ${method} ${url}`));
  });
}

async function renderPage(fetchMock: ReturnType<typeof createFetchMock>) {
  vi.stubGlobal("fetch", fetchMock);
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<CalculadoraPage />));
  await flush();
  return { node, root };
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

describe("calculator global rate inputs (post-ledger)", () => {
  it("renders the four Spanish-labeled global rate inputs", async () => {
    const fetchMock = createFetchMock({ ratesGet: { rates: null } });
    const { node, root } = await renderPage(fetchMock);

    expect(node.querySelector('label[for="tarifaCupGlobal"]')?.textContent).toBe("Tarifa CUP global");
    expect(node.querySelector('label[for="compraUsdtGyd"]')?.textContent).toBe("Compra USDT (GYD)");
    expect(node.querySelector('label[for="ventaUsdtGyd"]')?.textContent).toBe("Venta USDT/Zelle (GYD)");
    expect(node.querySelector('label[for="ventaUsdtCup"]')?.textContent).toBe("Venta USDT (CUP)");
    await act(async () => root.unmount());
  });

  it("no rates set yet -> every rate input is empty, never a fake default", async () => {
    const fetchMock = createFetchMock({ ratesGet: { rates: null } });
    const { node, root } = await renderPage(fetchMock);

    expect(inputValue(node, "tarifaCupGlobal")).toBe("");
    expect(inputValue(node, "compraUsdtGyd")).toBe("");
    expect(inputValue(node, "ventaUsdtGyd")).toBe("");
    expect(inputValue(node, "ventaUsdtCup")).toBe("");
    await act(async () => root.unmount());
  });

  it("hydrates saved rates from GET /api/calculator/rates", async () => {
    const fetchMock = createFetchMock({
      ratesGet: {
        rates: {
          id: "rate-1",
          cupGlobalRate: 3.5,
          usdtBuyGyd: 235,
          usdtSellGyd: 260,
          usdtSellCup: 975,
          effectiveAt: "2026-09-10T00:00:00Z",
          setBy: "user-a",
        },
      },
    });
    const { node, root } = await renderPage(fetchMock);

    expect(inputValue(node, "tarifaCupGlobal")).toBe("3.5");
    expect(inputValue(node, "compraUsdtGyd")).toBe("235");
    expect(inputValue(node, "ventaUsdtGyd")).toBe("260");
    expect(inputValue(node, "ventaUsdtCup")).toBe("975");
    await act(async () => root.unmount());
  });

  it("the debounced /api/calculadora save no longer carries rate fields", async () => {
    vi.useFakeTimers();
    const fetchMock = createFetchMock({ ratesGet: { rates: { id: "rate-1", cupGlobalRate: 3, usdtBuyGyd: null, usdtSellGyd: null, usdtSellCup: null, effectiveAt: "2026-09-10T00:00:00Z", setBy: null } } });
    const { node, root } = await renderPage(fetchMock);

    fetchMock.mockClear();
    act(() => setInputValue(node, "periodo", "SEMANA 2"));
    await act(async () => { await vi.advanceTimersByTimeAsync(600); });

    const postCall = fetchMock.mock.calls.find(
      ([input, init]) => (typeof input === "string" ? input : input.toString()) === "/api/calculadora" && (init as RequestInit)?.method === "POST",
    );
    expect(postCall).toBeDefined();
    const body = JSON.parse((postCall![1] as RequestInit).body as string);
    expect(body).toEqual({ rawText: "", periodo: "SEMANA 2" });
    await act(async () => root.unmount());
  });

  it("Guardar tasas sends only the filled-in rates, snake_case, with the loaded version id", async () => {
    let capturedBody: { rates: Record<string, unknown>; expectedVersionId?: string } | undefined;
    const ratesPost = vi.fn(
      (body: { rates: Record<string, unknown>; expectedVersionId?: string }): RatesPostResult => {
        capturedBody = body;
        return {
          status: 200,
          body: { rates: { id: "rate-2", cupGlobalRate: 4, usdtBuyGyd: 240, usdtSellGyd: null, usdtSellCup: null, effectiveAt: "2026-09-16T00:00:00Z", setBy: "user-a" } },
        };
      },
    );
    const fetchMock = createFetchMock({
      ratesGet: { rates: { id: "rate-1", cupGlobalRate: 3, usdtBuyGyd: null, usdtSellGyd: null, usdtSellCup: null, effectiveAt: "2026-09-10T00:00:00Z", setBy: null } },
      ratesPost,
    });
    const { node, root } = await renderPage(fetchMock);

    act(() => setInputValue(node, "tarifaCupGlobal", "4"));
    act(() => setInputValue(node, "compraUsdtGyd", "240"));
    const button = node.querySelector("#guardarTasas") as HTMLButtonElement;
    await act(async () => { button.click(); });
    await flush();

    expect(ratesPost).toHaveBeenCalledTimes(1);
    expect(capturedBody).toEqual({
      rates: { cup_global_rate: 4, usdt_buy_gyd: 240 },
      expectedVersionId: "rate-1",
    });
    // On success, local state (including the new version id for the next save) updates from the response.
    expect(inputValue(node, "tarifaCupGlobal")).toBe("4");
    expect(inputValue(node, "compraUsdtGyd")).toBe("240");
    await act(async () => root.unmount());
  });

  it("403 on Guardar tasas shows the admin-only message and disables rate inputs and the button", async () => {
    const fetchMock = createFetchMock({
      ratesGet: { rates: null },
      ratesPost: () => ({ status: 403, body: { error: "Forbidden" } }),
    });
    const { node, root } = await renderPage(fetchMock);

    act(() => setInputValue(node, "tarifaCupGlobal", "4"));
    const button = node.querySelector("#guardarTasas") as HTMLButtonElement;
    await act(async () => { button.click(); });
    await flush();

    expect(node.textContent).toContain("administrador");
    expect(isInputDisabled(node, "tarifaCupGlobal")).toBe(true);
    expect(isInputDisabled(node, "compraUsdtGyd")).toBe(true);
    expect(isInputDisabled(node, "ventaUsdtGyd")).toBe(true);
    expect(isInputDisabled(node, "ventaUsdtCup")).toBe(true);
    expect(button.disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("409 on Guardar tasas tells the user to reload, without disabling inputs", async () => {
    const fetchMock = createFetchMock({
      ratesGet: { rates: { id: "rate-1", cupGlobalRate: 3, usdtBuyGyd: null, usdtSellGyd: null, usdtSellCup: null, effectiveAt: "2026-09-10T00:00:00Z", setBy: null } },
      ratesPost: () => ({ status: 409, body: { error: "stale" } }),
    });
    const { node, root } = await renderPage(fetchMock);

    act(() => setInputValue(node, "tarifaCupGlobal", "4"));
    const button = node.querySelector("#guardarTasas") as HTMLButtonElement;
    await act(async () => { button.click(); });
    await flush();

    expect(node.textContent.toLowerCase()).toContain("recarg");
    expect(isInputDisabled(node, "tarifaCupGlobal")).toBe(false);
    expect(button.disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("other Guardar tasas failures show a generic save-failed message", async () => {
    const fetchMock = createFetchMock({
      ratesGet: { rates: null },
      ratesPost: () => ({ status: 500, body: { error: "boom" } }),
    });
    const { node, root } = await renderPage(fetchMock);

    act(() => setInputValue(node, "tarifaCupGlobal", "4"));
    const button = node.querySelector("#guardarTasas") as HTMLButtonElement;
    await act(async () => { button.click(); });
    await flush();

    expect(node.textContent).toContain("No se pudieron guardar las tasas");
    await act(async () => root.unmount());
  });
});

describe("calculator pending-entries banner", () => {
  it("shows a banner naming how many entries are pending and which rates they need", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "SEMANA 1",
        chatOperations: {
          entries: [
            {
              id: "entry-pending-1",
              operationId: "op-1",
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
            {
              id: "entry-pending-2",
              operationId: "op-2",
              status: "verified_pending",
              service: "ZELLE",
              customerName: "Raúl",
              amount: 100,
              amountCurrency: "USD",
              entryDate: "2026-09-12",
              facturadoGyd: null,
              invertidoGyd: null,
              retornoGyd: null,
              missingRates: ["usdtBuyGyd", "usdtSellGyd"],
            },
          ],
        },
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    expect(node.textContent).toContain("2");
    expect(node.textContent).toContain("Bladimir");
    expect(node.textContent).toContain("usdtSellCup");
    expect(node.textContent).toContain("Raúl");
    expect(node.textContent).toContain("usdtBuyGyd, usdtSellGyd");
    await act(async () => root.unmount());
  });

  it("shows no banner when there are no pending entries", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "",
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
          ],
        },
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    expect(node.querySelector("#pendingBanner")).toBeNull();
    await act(async () => root.unmount());
  });
});

describe("calculator chat operations (read-only)", () => {
  it("shows chat operations read-only and combines only completed snapshots", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "• Manual 1 USDT (240/260)",
        periodo: "SEMANA 1",
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
      },
      ratesGet: { rates: { id: "rate-1", cupGlobalRate: 3, usdtBuyGyd: 240, usdtSellGyd: 260, usdtSellCup: null, effectiveAt: "2026-09-10T00:00:00Z", setBy: null } },
    });
    const { node, root } = await renderPage(fetchMock);

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
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "SEMANA 1",
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
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    const montoCell = node.querySelector('td[data-label="Monto"]');
    expect(montoCell?.textContent).toBe("100 ZELLE");
    expect(node.textContent).not.toContain("100 USD");
    await act(async () => root.unmount());
  });
});
