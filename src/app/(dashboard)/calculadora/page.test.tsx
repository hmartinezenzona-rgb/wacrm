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

// Chainable `supabase.channel(...).on(...).subscribe()` mock, same shape
// `operations-panel-container.test.tsx` already uses, so B4.2's live
// "Operaciones del chat" feed (`use-calculator-entries-realtime`) can be
// driven from these tests without pulling in the real `@supabase/ssr`
// client (which needs env vars this test env doesn't set).
const mockRealtime = vi.hoisted(() => {
  interface MockChannel {
    name: string;
    handler: ((payload?: unknown) => void) | null;
    subscribeCalls: number;
    on: (event: string, filter: unknown, handler: (payload?: unknown) => void) => MockChannel;
    subscribe: () => MockChannel;
  }
  const channels: MockChannel[] = [];
  const removeChannelCalls: unknown[] = [];

  function channel(name: string): MockChannel {
    const chan: MockChannel = {
      name,
      handler: null,
      subscribeCalls: 0,
      on(_event, _filter, handler) {
        chan.handler = handler;
        return chan;
      },
      subscribe() {
        chan.subscribeCalls += 1;
        return chan;
      },
    };
    channels.push(chan);
    return chan;
  }

  function removeChannel(ch: unknown) {
    removeChannelCalls.push(ch);
  }

  function reset() {
    channels.length = 0;
    removeChannelCalls.length = 0;
  }

  return { channels, removeChannelCalls, channel, removeChannel, reset };
});

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ channel: mockRealtime.channel, removeChannel: mockRealtime.removeChannel }),
}));

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
type CorrectPostResult = { status: number; body?: unknown };

/** Routes the page's fetch calls by URL + method instead of a single blanket
 * mock, since the page now talks to two GET endpoints on hydration
 * (/api/calculadora and /api/calculator/rates) plus three POST endpoints
 * (document autosave, the explicit rate save, and per-entry corrections). */
function createFetchMock(config: {
  calculadoraGet?: unknown;
  ratesGet?: { rates: unknown };
  calculadoraPost?: unknown;
  ratesPost?: (body: { rates: Record<string, unknown>; expectedVersionId?: string }) => RatesPostResult;
  correctPost?: (entryId: string, body: { facturadoGyd: number; invertidoGyd: number }) => CorrectPostResult;
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
    const correctMatch = /^\/api\/calculator\/entries\/([^/]+)\/correct$/.exec(url);
    if (correctMatch && method === "POST") {
      const entryId = correctMatch[1]!;
      const body = JSON.parse((init?.body as string) ?? "{}");
      const result = config.correctPost
        ? config.correctPost(entryId, body)
        : {
            status: 200,
            body: {
              entry: {
                id: entryId,
                facturadoGyd: body.facturadoGyd,
                invertidoGyd: body.invertidoGyd,
                retornoGyd: body.facturadoGyd - body.invertidoGyd,
                status: "completed",
              },
            },
          };
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
  mockRealtime.reset();
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

    expect(node.textContent).toContain("Operaciones del chat");
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

describe("calculator chat operations (realtime, B4.2)", () => {
  it("subscribes to remittance_calculator_entries after hydration", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", chatOperations: { entries: [] } },
      ratesGet: { rates: null },
    });
    const { root } = await renderPage(fetchMock);

    expect(mockRealtime.channels).toHaveLength(1);
    const chan = mockRealtime.channels[0]!;
    expect(chan.subscribeCalls).toBe(1);
    expect(chan.handler).not.toBeNull();

    await act(async () => root.unmount());
    expect(mockRealtime.removeChannelCalls).toHaveLength(1);
  });

  it("an INSERT event adds a new completed entry with no refetch", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", chatOperations: { entries: [] } },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);
    fetchMock.mockClear();

    const chan = mockRealtime.channels[0]!;
    act(() => {
      chan.handler!({
        eventType: "INSERT",
        new: {
          id: "entry-live",
          operation_id: "op-live",
          status: "completed",
          service: "ZELLE",
          customer_name: "Raúl",
          amount: "100",
          amount_currency: "USD",
          entry_date: "2026-09-29",
          facturado_gyd: "26000",
          invertido_gyd: "24000",
          retorno_gyd: "2000",
          missing_inputs: [],
          source: "completed_operation",
        },
        old: {},
      });
    });

    expect(node.textContent).toContain("Raúl");
    expect(node.textContent).toContain("26000.00");
    // No page-refresh round trip: the live row came from the channel event,
    // not a re-fetch of /api/calculadora.
    expect(fetchMock).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("an UPDATE to void removes an entry the initial load had shown", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "",
        chatOperations: {
          entries: [
            {
              id: "entry-a",
              operationId: "op-a",
              status: "completed",
              service: "ZELLE",
              customerName: "Raúl",
              amount: 100,
              amountCurrency: "USD",
              entryDate: "2026-09-29",
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
    expect(node.textContent).toContain("Raúl");

    const chan = mockRealtime.channels[0]!;
    act(() => {
      chan.handler!({
        eventType: "UPDATE",
        new: {
          id: "entry-a",
          operation_id: "op-a",
          status: "void",
          service: "ZELLE",
          customer_name: "Raúl",
          amount: "100",
          amount_currency: "USD",
          entry_date: "2026-09-29",
          facturado_gyd: "26000",
          invertido_gyd: "24000",
          retorno_gyd: "2000",
          missing_inputs: [],
          source: "completed_operation",
        },
        old: { id: "entry-a" },
      });
    });

    expect(node.textContent).not.toContain("Raúl");
    await act(async () => root.unmount());
  });
});

describe("calculator chat operations (admin correction)", () => {
  const COMPLETED_ENTRY = {
    id: "entry-a",
    operationId: "op-a",
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
  };
  const PENDING_ENTRY = {
    id: "entry-b",
    operationId: "op-b",
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
  };

  function fixture(overrides?: { correctPost?: (entryId: string, body: { facturadoGyd: number; invertidoGyd: number }) => CorrectPostResult }) {
    return createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "SEMANA 1",
        chatOperations: { entries: [COMPLETED_ENTRY, PENDING_ENTRY] },
      },
      ratesGet: { rates: null },
      ...overrides,
    });
  }

  it("shows the Editar button only on completed entries", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    expect(node.querySelector("#editarEntry-entry-a")).not.toBeNull();
    expect(node.querySelector("#editarEntry-entry-b")).toBeNull();
    await act(async () => root.unmount());
  });

  it("renders Editar as a compact icon button with an accessible name", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const editButton = node.querySelector("#editarEntry-entry-a") as HTMLButtonElement;
    expect(editButton.getAttribute("aria-label")).toBe("Editar");
    expect(editButton.getAttribute("title")).toBe("Editar");
    expect(editButton.classList.contains("legacyIconButton")).toBe(true);
    expect(editButton.querySelector("svg")).not.toBeNull();
    expect(editButton.textContent?.trim()).toBe("");
    await act(async () => root.unmount());
  });

  it("editing and saving successfully updates the displayed values and closes the editor", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const editButton = node.querySelector("#editarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { editButton.click(); });

    expect(inputValue(node, "editFacturado-entry-a")).toBe("26000");
    act(() => setInputValue(node, "editFacturado-entry-a", "27000"));
    act(() => setInputValue(node, "editInvertido-entry-a", "24500"));

    const saveButton = node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { saveButton.click(); });
    await flush();

    const correctCall = fetchMock.mock.calls.find(([input]) =>
      (typeof input === "string" ? input : input.toString()) === "/api/calculator/entries/entry-a/correct",
    );
    expect(correctCall).toBeDefined();
    expect(JSON.parse((correctCall![1] as RequestInit).body as string)).toEqual({
      facturadoGyd: 27000,
      invertidoGyd: 24500,
    });
    expect(node.textContent).toContain("27000.00");
    expect(node.textContent).toContain("24500.00");
    expect(node.textContent).toContain("2500.00");
    expect(node.querySelector("#guardarEntry-entry-a")).toBeNull();
    expect(node.querySelector("#editarEntry-entry-a")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("a 403 response shows the admin-only message and closes the editor", async () => {
    const fetchMock = fixture({ correctPost: () => ({ status: 403, body: { error: "Forbidden" } }) });
    const { node, root } = await renderPage(fetchMock);

    const editButton = node.querySelector("#editarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { editButton.click(); });
    const saveButton = node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { saveButton.click(); });
    await flush();

    expect(node.textContent).toContain("Solo un administrador puede corregir esta operación.");
    expect(node.querySelector("#guardarEntry-entry-a")).toBeNull();
    expect(node.querySelector("#editarEntry-entry-a")).not.toBeNull();
    // Values are unchanged since the RPC never ran.
    expect(node.textContent).toContain("26000.00");
    await act(async () => root.unmount());
  });

  it("rejects an invalid input client-side without a network call", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const editButton = node.querySelector("#editarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { editButton.click(); });
    act(() => setInputValue(node, "editFacturado-entry-a", ""));
    fetchMock.mockClear();

    const saveButton = node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { saveButton.click(); });
    await flush();

    expect(fetchMock).not.toHaveBeenCalled();
    // The editor stays open so the admin can fix the value and retry.
    expect(node.querySelector("#guardarEntry-entry-a")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("rejects a negative input client-side without a network call", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const editButton = node.querySelector("#editarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { editButton.click(); });
    act(() => setInputValue(node, "editInvertido-entry-a", "-5"));
    fetchMock.mockClear();

    const saveButton = node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { saveButton.click(); });
    await flush();

    expect(fetchMock).not.toHaveBeenCalled();
    expect(node.querySelector("#guardarEntry-entry-a")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("Cancelar discards the in-progress edit without a network call", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const editButton = node.querySelector("#editarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { editButton.click(); });
    act(() => setInputValue(node, "editFacturado-entry-a", "99999"));
    fetchMock.mockClear();

    const cancelButton = node.querySelector("#cancelarEntry-entry-a") as HTMLButtonElement;
    await act(async () => { cancelButton.click(); });
    await flush();

    expect(fetchMock).not.toHaveBeenCalled();
    expect(node.querySelector("#editarEntry-entry-a")).not.toBeNull();
    expect(node.textContent).toContain("26000.00");
    expect(node.textContent).not.toContain("99999");
    await act(async () => root.unmount());
  });
});
