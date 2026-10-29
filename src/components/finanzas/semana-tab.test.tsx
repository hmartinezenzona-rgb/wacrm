// @vitest-environment jsdom
// Component-level coverage for the calculator page's rate handling after
// slice 9 moved the four global rates into the append-only
// calculator_rate_versions table:
//  - the rate inputs hydrate from GET /api/calculator/rates (never a fake
//    default like "3.0"), and its `id` is kept as the concurrency token;
//  - rates no longer ride the debounced POST /api/calculadora save;
//  - the single-rate editor (dropdown + value + "Actualizar") POSTs only the
//    selected rate (snake_case) plus expectedVersionId to POST /api/calculator/rates, and
//    reacts to 403 (admin-only, disables editing)/409 (stale, reload)/other
//    failures with Spanish messages;
//  - a pending banner lists chat entries stuck on verified_pending and the
//    rates they are missing.
// The legacy manual textarea formulas (web-calculator.ts) are untouched and
// are not re-tested here.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import esMessages from "../../../messages/es.json";
import { SemanaTab } from "./semana-tab";
import { num } from "@/lib/finanzas/number-format";

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
  ratesGet?: { rates: unknown; arqRate?: unknown };
  calculadoraPost?: unknown;
  ratesPost?: (body: { rates: Record<string, unknown>; expectedVersionId?: string }) => RatesPostResult;
  correctPost?: (entryId: string, body: { facturadoGyd: number; invertidoGyd: number }) => CorrectPostResult;
  deletePost?: (entryId: string) => { status: number; body?: unknown };
  ratesEntryPost?: (entryId: string, body: { usdtBuyGyd?: number; cupRate?: number }) => { status: number; body?: unknown };
  weeksGet?: { weeks: unknown[] };
  weeksPost?: (body: Record<string, unknown>) => { status: number; body?: unknown };
  weekGet?: (weekId: string) => { status: number; body?: unknown };
  entriesPost?: (body: { lines: Array<Record<string, unknown>> }) => { status: number; body?: unknown };
}) {
  return vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = init?.method ?? "GET";
    // Archived weeks (migration 227) and entry deletion (226) first: the document routes below match by prefix.
    if (url === "/api/calculadora/weeks" && method === "GET") {
      return Promise.resolve(jsonResponse(config.weeksGet ?? { weeks: [] }));
    }
    if (url === "/api/calculadora/weeks" && method === "POST") {
      const body = JSON.parse((init?.body as string) ?? "{}");
      const result = config.weeksPost
        ? config.weeksPost(body)
        : { status: 200, body: { week: { id: "week-new", cutAt: "2026-10-03T12:00:00+00:00" }, cutAt: "2026-10-03T12:00:00+00:00" } };
      return Promise.resolve(jsonResponse(result.body ?? {}, result.status));
    }
    if (url === "/api/calculadora/entries" && method === "POST") {
      const body = JSON.parse((init?.body as string) ?? "{}") as { lines: Array<Record<string, unknown>> };
      const result = config.entriesPost
        ? config.entriesPost(body)
        : {
            status: 200,
            body: {
              entries: body.lines.map((line, index) => ({
                id: `man-${index + 1}`, operationId: null, source: "manual", status: "completed", service: line.service,
                customerName: line.customer, amount: line.amount, amountCurrency: line.currency, entryDate: line.date,
                facturadoGyd: line.facturadoGyd, invertidoGyd: line.invertidoGyd, retornoGyd: line.retornoGyd, missingRates: [],
              })),
            },
          };
      return Promise.resolve(jsonResponse(result.body ?? {}, result.status));
    }
    const weekMatch = /^\/api\/calculadora\/weeks\/([^/]+)$/.exec(url);
    if (weekMatch && method === "GET") {
      const result = config.weekGet ? config.weekGet(weekMatch[1]!) : { status: 404, body: { error: "Not found" } };
      return Promise.resolve(jsonResponse(result.body ?? {}, result.status));
    }
    const deleteMatch = /^\/api\/calculator\/entries\/([^/]+)\/delete$/.exec(url);
    if (deleteMatch && method === "POST") {
      const result = config.deletePost
        ? config.deletePost(deleteMatch[1]!)
        : { status: 200, body: { deleted: true, entryId: deleteMatch[1] } };
      return Promise.resolve(jsonResponse(result.body ?? {}, result.status));
    }
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
    const entryRatesMatch = /^\/api\/calculator\/entries\/([^/]+)\/rates$/.exec(url);
    if (entryRatesMatch && method === "POST") {
      const entryId = entryRatesMatch[1]!;
      const body = JSON.parse((init?.body as string) ?? "{}");
      const result = config.ratesEntryPost ? config.ratesEntryPost(entryId, body) : { status: 500, body: { error: "unexpected" } };
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
  await act(async () => root.render(
    <NextIntlClientProvider locale="es" messages={{ ...esMessages, Common: { close: "Cerrar" } }}>
      <SemanaTab />
    </NextIntlClientProvider>,
  ));
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

const FULL_RATES = {
  id: "rate-1",
  cupGlobalRate: 3,
  usdtBuyGyd: 240,
  usdtSellGyd: 260,
  usdtSellCup: 975,
  zelleSellGyd: 260,
  zelleSellGyd1000: 250,
  zelleSellGyd2000: 245,
  efectivoUsdGyd: 290,
  recargaCostoUsdt: 4.5,
  saldoCostoUsdt: 1.25,
  recargaCostoUsdt500: 19.5,
  effectiveAt: "2026-09-10T00:00:00Z",
  setBy: null,
};

const rateRow = (node: HTMLElement, key: string) => node.querySelector(`[data-rate="${key}"]`) as HTMLElement;

/** The rows of "Tasas actuales" in screen order: [key, text] where text is the label, the value and the unit. */
function listRows(node: HTMLElement) {
  return [...node.querySelectorAll("[data-rate]")].map((row) => [row.getAttribute("data-rate"), row.textContent]);
}

/** Opens the in-place editor of one rate (a click on its row). */
function editRate(node: HTMLElement, key: string) {
  act(() => (rateRow(node, key).querySelector("button") as HTMLButtonElement).click());
}

function rateInput(node: HTMLElement, key: string) {
  return rateRow(node, key).querySelector("input") as HTMLInputElement;
}

function typeRate(node: HTMLElement, key: string, value: string) {
  const input = rateInput(node, key);
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

function saveButton(node: HTMLElement) {
  return node.querySelector('[data-testid="tasas-grupos"] button[aria-label="Guardar"]') as HTMLButtonElement;
}

describe("Tasas actuales: every rate, edited in place", () => {
  it("lists the eleven rates of the calculator in four groups, with their unit", async () => {
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES } }));

    expect(node.querySelectorAll('[data-testid="tasas-grupo"]')).toHaveLength(4);
    expect(listRows(node)).toEqual([
      ["usdt_buy_gyd", "Compra240GYD"],
      ["usdt_sell_gyd", "Ventatambién Clásica, Tropical y México260GYD"],
      ["usdt_sell_cup", "Venta en CUP975CUP"],
      ["zelle_sell_gyd", "Desde 50 USD260GYD"],
      ["zelle_sell_gyd_1000", "Desde 1,000 USD250GYD"],
      ["zelle_sell_gyd_2000", "Desde 2,000 USD245GYD"],
      ["recarga_costo_usdt_500", "Recarga desde 50019.5USDT"],
      ["recarga_costo_usdt", "Recarga desde 6004.5USDT"],
      ["saldo_costo_usdt", "Saldo móvil1.25USDT"],
      ["cup_global_rate", "Tarifa CUP global3"],
      ["efectivo_usd_gyd", "Efectivo USD290GYD"],
    ]);
    expect(node.querySelectorAll('[data-testid="tasas-grupos"] input').length).toBe(0);
    await act(async () => root.unmount());
  });

  it("shows a dash for the rates not set", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: { ...FULL_RATES, usdtSellCup: null, efectivoUsdGyd: null } } }),
    );

    expect(rateRow(node, "usdt_sell_cup").textContent).toBe("Venta en CUP—");
    expect(rateRow(node, "efectivo_usd_gyd").textContent).toBe("Efectivo USD—");
    await act(async () => root.unmount());
  });

  it("no rates set yet -> every value is a dash, never a fake default", async () => {
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: null } }));

    expect(node.querySelectorAll("[data-rate]")).toHaveLength(11);
    for (const row of node.querySelectorAll("[data-rate]")) expect(row.textContent).toContain("—");
    await act(async () => root.unmount());
  });

  it("pressing a rate opens an input holding its current value (empty when unset)", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: { ...FULL_RATES, usdtSellCup: null } } }),
    );

    editRate(node, "zelle_sell_gyd_1000");
    expect(rateInput(node, "zelle_sell_gyd_1000").value).toBe("250");
    editRate(node, "usdt_sell_cup");
    expect(rateInput(node, "usdt_sell_cup").value).toBe("");
    expect(node.querySelectorAll('[data-testid="tasas-grupos"] input')).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("Guardar posts only that rate with the loaded version id, refreshes the list and closes the editor", async () => {
    let capturedBody: { rates: Record<string, unknown>; expectedVersionId?: string } | undefined;
    const ratesPost = vi.fn((body: { rates: Record<string, unknown>; expectedVersionId?: string }): RatesPostResult => {
      capturedBody = body;
      return { status: 200, body: { rates: { ...FULL_RATES, id: "rate-2", zelleSellGyd1000: 255 } } };
    });
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

    editRate(node, "zelle_sell_gyd_1000");
    typeRate(node, "zelle_sell_gyd_1000", "255");
    await act(async () => { saveButton(node).click(); });
    await flush();

    expect(ratesPost).toHaveBeenCalledTimes(1);
    expect(capturedBody).toEqual({ rates: { zelle_sell_gyd_1000: 255 }, expectedVersionId: "rate-1" });
    expect(rateRow(node, "zelle_sell_gyd_1000").textContent).toBe("Desde 1,000 USD255GYD");
    expect(node.querySelectorAll('[data-testid="tasas-grupos"] input')).toHaveLength(0);
    expect(node.querySelector("#tasasMensaje")?.textContent).toContain("Tasa actualizada");
    await act(async () => root.unmount());
  });

  it("Enter saves and Escape cancels without a request", async () => {
    const ratesPost = vi.fn((): RatesPostResult => ({ status: 200, body: { rates: { ...FULL_RATES, id: "rate-2", cupGlobalRate: 4 } } }));
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "4");
    act(() => { rateInput(node, "cup_global_rate").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); });
    expect(ratesPost).not.toHaveBeenCalled();
    expect(node.querySelectorAll('[data-testid="tasas-grupos"] input')).toHaveLength(0);
    expect(rateRow(node, "cup_global_rate").textContent).toBe("Tarifa CUP global3");

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "4");
    await act(async () => { rateInput(node, "cup_global_rate").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); });
    await flush();
    expect(ratesPost).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("the next update uses the new version id from the response", async () => {
    const bodies: Array<{ rates: Record<string, unknown>; expectedVersionId?: string }> = [];
    const ratesPost = vi.fn((body: { rates: Record<string, unknown>; expectedVersionId?: string }): RatesPostResult => {
      bodies.push(body);
      return { status: 200, body: { rates: { ...FULL_RATES, id: `rate-${bodies.length + 1}`, cupGlobalRate: 4 } } };
    });
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "4");
    await act(async () => { saveButton(node).click(); });
    await flush();
    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "5");
    await act(async () => { saveButton(node).click(); });
    await flush();

    expect(bodies.map((b) => b.expectedVersionId)).toEqual(["rate-1", "rate-2"]);
    await act(async () => root.unmount());
  });

  it("with no version yet the post carries no expectedVersionId", async () => {
    const ratesPost = vi.fn((): RatesPostResult => ({ status: 200, body: { rates: { ...FULL_RATES, id: "rate-1", cupGlobalRate: 3 } } }));
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: null }, ratesPost }));

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "3");
    await act(async () => { saveButton(node).click(); });
    await flush();

    expect(ratesPost).toHaveBeenCalledWith({ rates: { cup_global_rate: 3 } });
    await act(async () => root.unmount());
  });

  it.each([["empty", ""], ["zero", "0"], ["negative", "-5"]])(
    "an invalid value (%s) is not sent and shows a message",
    async (_name, value) => {
      const ratesPost = vi.fn((): RatesPostResult => ({ status: 200, body: { rates: FULL_RATES } }));
      const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

      editRate(node, "cup_global_rate");
      typeRate(node, "cup_global_rate", value);
      await act(async () => { saveButton(node).click(); });
      await flush();

      expect(ratesPost).not.toHaveBeenCalled();
      expect(node.querySelector("#tasasMensaje")?.textContent).toContain("número mayor que 0");
      await act(async () => root.unmount());
    },
  );

  it("403 shows the admin-only message and locks every rate", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost: () => ({ status: 403, body: { error: "Forbidden" } }) }),
    );

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "4");
    await act(async () => { saveButton(node).click(); });
    await flush();

    expect(node.querySelector("#tasasMensaje")?.textContent).toContain("Solo un administrador puede modificar las tasas.");
    expect(rateInput(node, "cup_global_rate").disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("409 tells the user to reload, without locking anything", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost: () => ({ status: 409, body: { error: "stale" } }) }),
    );

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "4");
    await act(async () => { saveButton(node).click(); });
    await flush();

    expect(node.textContent).toContain("Las tasas se modificaron en otro lugar; recarga la página.");
    expect(rateInput(node, "cup_global_rate").disabled).toBe(false);
    expect(saveButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("other failures show a generic save-failed message and keep the list", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost: () => ({ status: 500, body: { error: "boom" } }) }),
    );

    editRate(node, "cup_global_rate");
    typeRate(node, "cup_global_rate", "4");
    await act(async () => { saveButton(node).click(); });
    await flush();

    expect(node.textContent).toContain("No se pudieron guardar las tasas.");
    await act(async () => root.unmount());
  });

  it("the debounced /api/calculadora save no longer carries rate fields", async () => {
    vi.useFakeTimers();
    const fetchMock = createFetchMock({ ratesGet: { rates: FULL_RATES } });
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

  const comboEntry = (overrides: Record<string, unknown>) => ({
    id: "entry-combo",
    operationId: "op-combo",
    source: "completed_operation",
    status: "verified_pending",
    service: "COMBO",
    customerName: "Marta",
    amount: 55000,
    amountCurrency: "GYD",
    entryDate: "2026-10-04",
    facturadoGyd: null,
    invertidoGyd: null,
    retornoGyd: null,
    missingRates: ["comboCosto"],
    ...overrides,
  });

  it("a pending COMBO line asks for the cost in the conversation panel, not for rates", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", chatOperations: { entries: [comboEntry({})] } },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    expect(node.querySelector('td[data-label="Cliente"]')!.textContent).toBe("Marta");
    const row = node.querySelector('td[data-label="Estado"]')!;
    expect(row.textContent).toContain("Pendiente");
    expect(row.textContent).toContain("Falta el costo del combo: anótalo en el panel de la conversación");
    expect(row.textContent).not.toContain("comboCosto");
    // No rates-resolution action on a COMBO line: the only action is the delete (migration 226).
    const actions = [...node.querySelector('td[data-label="Acciones"]')!.querySelectorAll("button")];
    expect(actions.map((button) => button.getAttribute("aria-label"))).toEqual(["Eliminar"]);
    await act(async () => root.unmount());
  });

  it("a priced COMBO line shows its figures as Completada, with no pending banner", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "",
        chatOperations: {
          entries: [comboEntry({ status: "completed", facturadoGyd: 55000, invertidoGyd: 41000, retornoGyd: 14000, missingRates: [] })],
        },
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    expect(node.querySelector("[data-show]")).toBeNull();
    const cells = Array.from(node.querySelectorAll("#cardRegistros td")).map((c) => c.textContent);
    expect(cells).toContain("Completada");
    expect(node.textContent).toContain("55,000");
    expect(node.textContent).toContain("41,000");
    expect(node.textContent).toContain("14,000");
    expect(node.textContent).not.toContain("Falta el costo");
    await act(async () => root.unmount());
  });

  it("the banner keeps naming the missing rates for non-COMBO lines next to a COMBO one", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "",
        chatOperations: {
          entries: [
            comboEntry({}),
            comboEntry({ id: "entry-cup", service: "CUP", customerName: "Bladimir", missingRates: ["usdtSellCup"] }),
          ],
        },
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    const [combo, cup] = [...node.querySelectorAll("tr[data-entry]")];
    expect(combo!.querySelector('td[data-label="Estado"]')!.textContent).toContain("Falta el costo del combo");
    expect(cup!.querySelector('td[data-label="Cliente"]')!.textContent).toBe("Bladimir");
    expect(cup!.querySelector('td[data-label="Servicio"]')!.textContent).toBe("CUP");
    expect(cup!.querySelector('td[data-label="Estado"]')!.textContent).toBe("Sin tasausdtSellCup");
    await act(async () => root.unmount());
  });

  it("a saldo line reads as its saldo amount in SM with the Saldo móvil label, not '5 SALDO_MOVIL'", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "",
        chatOperations: {
          entries: [
            comboEntry({
              service: "SALDO_MOVIL",
              customerName: "Yilian",
              amount: 1800,
              amountCurrency: "SM",
              status: "completed",
              facturadoGyd: 5000,
              invertidoGyd: 1500,
              retornoGyd: 3500,
              missingRates: [],
            }),
          ],
        },
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    expect(node.querySelector('td[data-label="Monto"]')!.textContent).toBe("1,800 SM");
    expect(node.querySelector('td[data-label="Servicio"]')!.textContent).toBe("Saldo móvil");
    expect(node.textContent).not.toContain("SALDO_MOVIL");
    await act(async () => root.unmount());
  });

  it("a pending saldo line names the service as Saldo móvil in the banner", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "",
        periodo: "",
        chatOperations: {
          entries: [comboEntry({ service: "SALDO_MOVIL", customerName: "Yilian", amount: 1800, amountCurrency: "SM", missingRates: ["saldoCostoUsdt"] })],
        },
      },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);

    const row = node.querySelector("tr[data-entry]")!;
    expect(row.querySelector('td[data-label="Cliente"]')!.textContent).toBe("Yilian");
    expect(row.querySelector('td[data-label="Servicio"]')!.textContent).toBe("Saldo móvil");
    expect(row.querySelector('td[data-label="Estado"]')!.textContent).toContain("saldoCostoUsdt");
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

    expect(node.querySelector("[data-show]")).toBeNull();
    await act(async () => root.unmount());
  });
});

describe("calculator chat operations (read-only)", () => {
  it("shows the operations table and totals from the completed entries only; the draft text does not count until it is registered", async () => {
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

    expect(node.textContent).toContain("Registros de la semana");
    expect(node.textContent).not.toContain("Operaciones del chat");
    expect(node.textContent).toContain("Completada");
    expect(node.textContent).toContain("Sin tasa");
    expect(node.textContent).toContain("usdtSellCup");
    // the draft "Manual 1 USDT (240/260)" would add 260 / 240 / 20: it is not an operation yet
    const totals = [...node.querySelectorAll('[data-testid="registros-totales"] td[data-label]')].map((td) => td.textContent);
    expect(totals).toEqual(["26,000", "24,000", "2,000"]);
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
    expect(node.textContent).toContain("26,000");
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
    expect(editButton.classList.contains("rowIconButton")).toBe(true);
    expect(editButton.querySelector("svg")).not.toBeNull();
    expect(editButton.textContent?.trim()).toBe("");
    await act(async () => root.unmount());
  });

  it("sizes the Acciones column to its content instead of sharing the table width", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const header = Array.from(node.querySelectorAll("th")).find((th) => th.textContent === "Acciones");
    const cell = node.querySelector("#editarEntry-entry-a")?.closest("td");
    expect(header?.classList.contains("actionsCell")).toBe(true);
    expect(cell?.classList.contains("actionsCell")).toBe(true);
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
    expect(node.textContent).toContain("27,000");
    expect(node.textContent).toContain("24,500");
    expect(node.textContent).toContain("2,500");
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
    expect(node.textContent).toContain("26,000");
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
    expect(node.textContent).toContain("26,000");
    expect(node.textContent).not.toContain("99999");
    await act(async () => root.unmount());
  });

  it("the edit row uses check and X icon buttons with aria-label and title, not text buttons", async () => {
    const { node, root } = await renderPage(fixture());
    await act(async () => { (node.querySelector("#editarEntry-entry-a") as HTMLButtonElement).click(); });

    const save = node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement;
    const cancel = node.querySelector("#cancelarEntry-entry-a") as HTMLButtonElement;
    expect(save.getAttribute("aria-label")).toBe("Guardar");
    expect(save.getAttribute("title")).toBe("Guardar");
    expect(cancel.getAttribute("aria-label")).toBe("Cancelar");
    expect(cancel.getAttribute("title")).toBe("Cancelar");
    for (const button of [save, cancel]) {
      expect(button.classList.contains("rowIconButton")).toBe(true);
      expect(button.querySelector("svg")).not.toBeNull();
      expect(button.textContent).toBe("");
    }
    await act(async () => root.unmount());
  });

  it("Enter in an edit input saves and Escape cancels", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await act(async () => { (node.querySelector("#editarEntry-entry-a") as HTMLButtonElement).click(); });
    const key = (id: string, k: string) => act(async () => {
      node.querySelector(`#${id}`)!.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));
    });

    act(() => setInputValue(node, "editFacturado-entry-a", "99999"));
    fetchMock.mockClear();
    await key("editFacturado-entry-a", "Escape");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(node.querySelector("#guardarEntry-entry-a")).toBeNull();

    await act(async () => { (node.querySelector("#editarEntry-entry-a") as HTMLButtonElement).click(); });
    act(() => setInputValue(node, "editInvertido-entry-a", "24500"));
    await key("editInvertido-entry-a", "Enter");
    await flush();
    expect(calls(fetchMock, "POST", "/api/calculator/entries/entry-a/correct")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("while saving, both edit buttons are disabled and the check shows a pending cue", async () => {
    let release: (() => void) | undefined;
    const fetchMock = fixture();
    const base = fetchMock.getMockImplementation()!;
    fetchMock.mockImplementation((input, init) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.endsWith("/entry-a/correct")) {
        return new Promise<Response>((resolve) => { release = () => resolve(jsonResponse({ error: "x" }, 500)); });
      }
      return base(input, init);
    });
    const { node, root } = await renderPage(fetchMock);
    await act(async () => { (node.querySelector("#editarEntry-entry-a") as HTMLButtonElement).click(); });
    await act(async () => { (node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement).click(); });

    const save = node.querySelector("#guardarEntry-entry-a") as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    expect(save.getAttribute("aria-busy")).toBe("true");
    expect(save.querySelector("svg.animate-spin")).not.toBeNull();
    expect((node.querySelector("#cancelarEntry-entry-a") as HTMLButtonElement).disabled).toBe(true);
    await act(async () => { release!(); });
    await flush();
    await act(async () => root.unmount());
  });
});


function calls(fetchMock: ReturnType<typeof createFetchMock>, method: string, urlPrefix: string) {
  return fetchMock.mock.calls.filter(([input, init]) => {
    const url = typeof input === "string" ? input : input.toString();
    return url.startsWith(urlPrefix) && (init?.method ?? "GET") === method;
  });
}

const DEL_COMPLETED = {
  id: "entry-a", operationId: "op-a", status: "completed", service: "ZELLE", customerName: "Raúl", amount: 100,
  amountCurrency: "USD", entryDate: "2026-09-12", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, missingRates: [],
};
const DEL_PENDING = {
  id: "entry-b", operationId: "op-b", status: "verified_pending", service: "CUP", customerName: "Bladimir", amount: 30000,
  amountCurrency: "CUP", entryDate: "2026-09-12", facturadoGyd: null, invertidoGyd: null, retornoGyd: null, missingRates: ["usdtSellCup"],
};

describe("calculator chat operations (admin delete)", () => {
  function fixture(overrides: Parameters<typeof createFetchMock>[0] = {}) {
    return createFetchMock({
      calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [DEL_COMPLETED, DEL_PENDING] } },
      ratesGet: { rates: null },
      ...overrides,
    });
  }

  it("shows a trash icon button next to the pencil on completed and on pending entries", async () => {
    const { node, root } = await renderPage(fixture());

    for (const id of ["entry-a", "entry-b"]) {
      const button = node.querySelector(`#eliminarEntry-${id}`) as HTMLButtonElement;
      expect(button).not.toBeNull();
      expect(button.getAttribute("aria-label")).toBe("Eliminar");
      expect(button.getAttribute("title")).toBe("Eliminar");
      expect(button.classList.contains("rowIconButton")).toBe(true);
      expect(button.querySelector("svg")).not.toBeNull();
    }
    expect(node.querySelector("#editarEntry-entry-a")).not.toBeNull();
    await act(async () => root.unmount());
  });

  function byId(node: HTMLElement, id: string) {
    return node.querySelector(`#${id}`) as HTMLButtonElement | null;
  }
  async function askDelete(node: HTMLElement, id: string) {
    await act(async () => { byId(node, `eliminarEntry-${id}`)!.click(); });
  }
  async function confirmDelete(node: HTMLElement, id: string) {
    await askDelete(node, id);
    await act(async () => { byId(node, `confirmarEliminar-${id}`)!.click(); });
  }

  it("the trash asks inline in that row (X and check), never through window.confirm, and sends nothing yet", async () => {
    const confirm = vi.spyOn(window, "confirm");
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    await askDelete(node, "entry-a");

    const row = byId(node, "confirmarEliminar-entry-a")!.closest("tr")!;
    expect(row.textContent).toContain("¿Eliminar?");
    const ok = byId(node, "confirmarEliminar-entry-a")!;
    const cancel = byId(node, "cancelarEliminar-entry-a")!;
    expect(ok.getAttribute("aria-label")).toBe("Eliminar");
    expect(ok.getAttribute("title")).toBe("Eliminar");
    expect(ok.classList.contains("rowIconButton")).toBe(true);
    expect(ok.querySelector("svg")).not.toBeNull();
    expect(cancel.getAttribute("aria-label")).toBe("Cancelar");
    expect(cancel.getAttribute("title")).toBe("Cancelar");
    expect(cancel.classList.contains("rowIconButton")).toBe(true);
    // pencil and trash are hidden in that row meanwhile
    expect(byId(node, "eliminarEntry-entry-a")).toBeNull();
    expect(byId(node, "editarEntry-entry-a")).toBeNull();
    // the other row is untouched
    expect(byId(node, "eliminarEntry-entry-b")).not.toBeNull();
    expect(confirm).not.toHaveBeenCalled();
    expect(calls(fetchMock, "POST", "/api/calculator/entries")).toHaveLength(0);
    expect(node.textContent).toContain("26,000");
    await act(async () => root.unmount());
  });

  it("X cancels: the row goes back to pencil and trash and nothing is sent", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    await askDelete(node, "entry-a");
    await act(async () => { byId(node, "cancelarEliminar-entry-a")!.click(); });

    expect(byId(node, "confirmarEliminar-entry-a")).toBeNull();
    expect(byId(node, "eliminarEntry-entry-a")).not.toBeNull();
    expect(byId(node, "editarEntry-entry-a")).not.toBeNull();
    expect(node.textContent).not.toContain("¿Eliminar?");
    expect(calls(fetchMock, "POST", "/api/calculator/entries")).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("Escape cancels the confirmation without a request", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    await askDelete(node, "entry-a");
    await act(async () => { document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); });

    expect(byId(node, "confirmarEliminar-entry-a")).toBeNull();
    expect(byId(node, "eliminarEntry-entry-a")).not.toBeNull();
    expect(calls(fetchMock, "POST", "/api/calculator/entries")).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("only one row confirms at a time: asking on another row moves the confirmation", async () => {
    const { node, root } = await renderPage(fixture());

    await askDelete(node, "entry-a");
    await askDelete(node, "entry-b");

    expect(byId(node, "confirmarEliminar-entry-a")).toBeNull();
    expect(byId(node, "eliminarEntry-entry-a")).not.toBeNull();
    expect(byId(node, "confirmarEliminar-entry-b")).not.toBeNull();
    expect(node.textContent!.match(/¿Eliminar\?/g)).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("while the delete runs both buttons are disabled and the check shows a pending cue", async () => {
    let release: (() => void) | undefined;
    const fetchMock = fixture();
    const base = fetchMock.getMockImplementation()!;
    fetchMock.mockImplementation((input, init) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.endsWith("/entry-a/delete")) {
        return new Promise<Response>((resolve) => { release = () => resolve(jsonResponse({ ok: true })); });
      }
      return base(input, init);
    });
    const { node, root } = await renderPage(fetchMock);

    await confirmDelete(node, "entry-a");

    expect(byId(node, "confirmarEliminar-entry-a")!.disabled).toBe(true);
    expect(byId(node, "cancelarEliminar-entry-a")!.disabled).toBe(true);
    expect(byId(node, "confirmarEliminar-entry-a")!.getAttribute("aria-busy")).toBe("true");
    expect(byId(node, "confirmarEliminar-entry-a")!.querySelector("svg.animate-spin")).not.toBeNull();

    await act(async () => { release!(); });
    await flush();
    expect(byId(node, "confirmarEliminar-entry-a")).toBeNull();
    expect(byId(node, "eliminarEntry-entry-a")).toBeNull();
    await act(async () => root.unmount());
  });

  it("confirming deletes the entry: the line disappears and the totals drop it", async () => {
    const confirm = vi.spyOn(window, "confirm");
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    expect(node.querySelector('[data-testid="registros-totales"] td[data-label="Facturado"]')?.textContent).toContain("26,000");

    await confirmDelete(node, "entry-a");
    await flush();

    expect(calls(fetchMock, "POST", "/api/calculator/entries/entry-a/delete")).toHaveLength(1);
    expect(node.querySelector("#eliminarEntry-entry-a")).toBeNull();
    expect(node.querySelector("#eliminarEntry-entry-b")).not.toBeNull();
    expect(node.querySelector('[data-testid="registros-totales"] td[data-label="Facturado"]')?.textContent).toContain("0");
    expect(node.querySelector('[data-testid="registros-totales"] td[data-label="Facturado"]')?.textContent).not.toContain("26,000");
    expect(confirm).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("a pending entry can be deleted too", async () => {
    const confirm = vi.spyOn(window, "confirm");
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    await confirmDelete(node, "entry-b");
    await flush();

    expect(calls(fetchMock, "POST", "/api/calculator/entries/entry-b/delete")).toHaveLength(1);
    expect(node.querySelector("#eliminarEntry-entry-b")).toBeNull();
    expect(node.querySelector("#pendingBanner")).toBeNull();
    expect(confirm).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("a 403 keeps the line and says only an administrator can delete", async () => {
    const confirm = vi.spyOn(window, "confirm");
    const { node, root } = await renderPage(fixture({ deletePost: () => ({ status: 403, body: { error: "Forbidden" } }) }));

    await confirmDelete(node, "entry-a");
    await flush();

    expect(node.querySelector("#eliminarEntry-entry-a")).not.toBeNull();
    expect(node.textContent).toContain("Solo un administrador puede eliminar esta operación.");
    expect(confirm).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("another failure keeps the line and shows an error", async () => {
    const confirm = vi.spyOn(window, "confirm");
    const { node, root } = await renderPage(fixture({ deletePost: () => ({ status: 500, body: {} }) }));

    await confirmDelete(node, "entry-a");
    await flush();

    expect(node.querySelector("#eliminarEntry-entry-a")).not.toBeNull();
    expect(node.textContent).toContain("No se pudo eliminar la operación.");
    expect(confirm).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});

describe("calculator weekly cut (Limpiar Todo)", () => {
  const MANUAL = "Miércoles 5\n• Fran 50k CUP (235/980)";
  function fixture(overrides: Parameters<typeof createFetchMock>[0] = {}) {
    return createFetchMock({
      calculadoraGet: { rawText: MANUAL, periodo: "SEMANA 1", chatOperations: { entries: [DEL_COMPLETED, DEL_PENDING] } },
      ratesGet: { rates: FULL_RATES },
      ...overrides,
    });
  }
  function clearButton(node: HTMLElement) {
    return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.includes("Limpiar Todo")) as HTMLButtonElement;
  }

  function dialogButton(label: string) {
    return Array.from(document.querySelectorAll("[role=dialog] button")).find((b) => b.textContent?.trim() === label) as HTMLButtonElement | undefined;
  }
  async function confirmCut(node: HTMLElement) {
    await act(async () => { clearButton(node).click(); });
    await act(async () => { dialogButton("Limpiar todo")!.click(); });
  }

  it("Limpiar Todo opens the app's own dialog (no window.confirm); Cancelar closes it and sends nothing", async () => {
    const confirm = vi.spyOn(window, "confirm");
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    expect(document.querySelector("[role=dialog]")).toBeNull();

    await act(async () => { clearButton(node).click(); });

    const dialog = document.querySelector("[role=dialog]")!;
    expect(dialog).not.toBeNull();
    expect(dialog.textContent).toContain("¿Limpiar todo y empezar una semana nueva?");
    expect(dialog.textContent).toContain("«Cierres»");
    expect(dialog.textContent).toContain("Finanzas");
    expect(dialog.textContent).toContain("historial");
    // rendered in a portal on the body, not inside the page
    expect(node.contains(dialog)).toBe(false);
    expect(confirm).not.toHaveBeenCalled();

    await act(async () => { dialogButton("Cancelar")!.click(); });
    await flush();

    expect(document.querySelector("[role=dialog]")).toBeNull();
    expect(confirm).not.toHaveBeenCalled();
    expect(calls(fetchMock, "POST", "/api/calculadora/weeks")).toHaveLength(0);
    expect(calls(fetchMock, "POST", "/api/calculadora/weeks")).toHaveLength(0);
    expect((node.querySelector("#rawText") as HTMLTextAreaElement).value).toBe(MANUAL);
    expect(node.textContent).toContain("Raúl");
    await act(async () => root.unmount());
  });

  it("confirming archives the week through the server: the draft text and the period (the totals are computed in the database)", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    await confirmCut(node);
    await flush();

    const posts = calls(fetchMock, "POST", "/api/calculadora/weeks");
    expect(posts).toHaveLength(1);
    expect(JSON.parse((posts[0]![1] as RequestInit).body as string)).toEqual({ rawText: MANUAL, periodo: "SEMANA 1" });
    await act(async () => root.unmount());
  });

  it("after the cut the week is empty: no text, no period, no completed chat entry; a pending line stays; the keys are cleared", async () => {
    const { node, root } = await renderPage(fixture());
    expect(localStorage.getItem("remesas_rawText")).toBe(MANUAL);

    await confirmCut(node);
    await flush();

    expect((node.querySelector("#rawText") as HTMLTextAreaElement).value).toBe("");
    expect(inputValue(node, "periodo")).toBe("");
    expect(node.querySelector("#eliminarEntry-entry-a")).toBeNull();
    expect(node.querySelector("#eliminarEntry-entry-b")).not.toBeNull();
    expect(node.querySelector('[data-show="sinTasa"]')).not.toBeNull();
    expect(node.querySelector('[data-testid="registros-totales"] td[data-label="Facturado"]')?.textContent).toContain("0");
    await act(async () => root.unmount());
  });

  it("a failed cut changes nothing and says so", async () => {
    const { node, root } = await renderPage(fixture({ weeksPost: () => ({ status: 500, body: {} }) }));

    await confirmCut(node);
    await flush();

    expect((node.querySelector("#rawText") as HTMLTextAreaElement).value).toBe(MANUAL);
    expect(node.querySelector("#eliminarEntry-entry-a")).not.toBeNull();
    expect(node.textContent).toContain("No se pudo limpiar la semana");
    await act(async () => root.unmount());
  });

  it("the autosave cannot write the old text back after the cut", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    vi.useFakeTimers();

    // typing schedules the debounced save; the cut happens before it fires
    const textarea = node.querySelector("#rawText") as HTMLTextAreaElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!;
    await act(async () => { setter.call(textarea, `${MANUAL}\n• Ana 10k CUP (235/980)`); textarea.dispatchEvent(new Event("input", { bubbles: true })); });
    await confirmCut(node);
    await flush();
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    await flush();

    const saves = calls(fetchMock, "POST", "/api/calculadora").filter(([input]) => (typeof input === "string" ? input : input.toString()) === "/api/calculadora");
    const bodies = saves.map(([, init]) => JSON.parse((init as RequestInit).body as string) as { rawText: string; periodo: string });
    expect(bodies.every((body) => body.rawText === "" && body.periodo === "")).toBe(true);
    await act(async () => root.unmount());
  });

  it("the dialog closes once the cut succeeds, and while it runs the confirm button is disabled", async () => {
    let release: (() => void) | undefined;
    const fetchMock = fixture();
    const base = fetchMock.getMockImplementation()!;
    fetchMock.mockImplementation((input, init) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url === "/api/calculadora/weeks" && init?.method === "POST") {
        return new Promise<Response>((resolve) => { release = () => resolve(jsonResponse({ cutAt: "2026-10-10T12:00:00+00:00" })); });
      }
      return base(input, init);
    });
    const { node, root } = await renderPage(fetchMock);

    await confirmCut(node);
    expect(dialogButton("Limpiando…")!.disabled).toBe(true);
    expect(dialogButton("Cancelar")!.disabled).toBe(true);

    await act(async () => { release!(); });
    await flush();
    expect(document.querySelector("[role=dialog]")).toBeNull();
    expect((node.querySelector("#rawText") as HTMLTextAreaElement).value).toBe("");
    await act(async () => root.unmount());
  });
});

describe("calculator live entries after a weekly cut", () => {
  // The archived weeks live in the Cierres tab (archived-weeks.tsx); the Semana tab no longer lists them.
  it("does not list the archived weeks; the overview reads them only to compare", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", chatOperations: { entries: [] } },
      ratesGet: { rates: null },
      weeksGet: { weeks: [{ id: "week-1", cutAt: "2026-10-03T12:00:00+00:00", periodo: "SEMANA 1", manualTotals: {}, chatTotals: {} }] },
    });
    const { node, root } = await renderPage(fetchMock);
    expect(node.querySelector("#semanasAnteriores")).toBeNull();
    expect(node.textContent).not.toContain("Semanas anteriores");
    expect(fetchMock.mock.calls.some(([url]) => String(url) === "/api/calculadora/weeks")).toBe(true);
    await act(async () => root.unmount());
  });

  it("shows the overview above the calculator and wires its actions to the existing box and weekly cut", async () => {
    const today = new Date().toISOString().slice(0, 10);
    const fetchMock = createFetchMock({
      calculadoraGet: {
        rawText: "", periodo: "",
        chatOperations: { entries: [{
          id: "c1", operationId: "op-1", source: "completed_operation", status: "completed", service: "ZELLE", customerName: "Ana",
          amount: 100, amountCurrency: "USD", entryDate: today, facturadoGyd: 30000, invertidoGyd: 27000, retornoGyd: 3000, missingRates: [],
        }] },
      },
      ratesGet: { rates: null },
    });
    // jsdom has no layout, so no scrollIntoView.
    Element.prototype.scrollIntoView = vi.fn();
    const { node, root } = await renderPage(fetchMock);
    const overview = node.querySelector('section[aria-label="Resumen de la semana abierta"]')!;
    expect(overview.textContent).toContain("Ganancia de la semana");
    expect(overview.textContent).toContain("Ana");
    // Above the calculator's own content.
    expect(overview.compareDocumentPosition(node.querySelector("#rawText")!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    const actions = [...overview.querySelectorAll("button")];
    await act(async () => { actions.find((b) => b.textContent === "+ Registrar línea")!.click(); });
    expect(document.activeElement).toBe(node.querySelector("#rawText"));
    await act(async () => { actions.find((b) => b.textContent === "Revisar y cerrar semana")!.click(); });
    expect(document.querySelector("[role=dialog]")!.textContent).toContain("¿Limpiar todo y empezar una semana nueva?");
    await act(async () => root.unmount());
  });

  it("a live completed entry older than the latest cut does not reappear; one after it does", async () => {
    const fetchMock = createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", cutAt: "2026-10-03T12:00:00+00:00", chatOperations: { entries: [] } },
      ratesGet: { rates: null },
    });
    const { node, root } = await renderPage(fetchMock);
    const chan = mockRealtime.channels[0]!;
    const live = (id: string, completedAt: string, name: string) => ({
      eventType: "UPDATE",
      new: {
        id, operation_id: `op-${id}`, status: "completed", service: "ZELLE", customer_name: name, amount: "100", amount_currency: "USD",
        entry_date: "2026-10-01", facturado_gyd: "26000", invertido_gyd: "24000", retorno_gyd: "2000", missing_inputs: [],
        source: "completed_operation", completed_at: completedAt,
      },
      old: {},
    });

    act(() => { chan.handler!(live("old", "2026-10-01T10:00:00Z", "Vieja Vera")); });
    expect(node.textContent).not.toContain("Vieja Vera");
    act(() => { chan.handler!(live("new", "2026-10-04T10:00:00Z", "Nueva Nora")); });
    expect(node.textContent).toContain("Nueva Nora");
    await act(async () => root.unmount());
  });
});

describe("manual operations as rows of the one table (migration 228)", () => {
  const MANUAL_ROW = {
    id: "man-iza", operationId: null, source: "manual", status: "completed", service: "DIRECTO", customerName: "Iza", amount: 4000,
    amountCurrency: "GYD", entryDate: "2026-10-06", facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000, missingRates: [],
  };
  const MANUAL_ZELLE = {
    id: "man-pedro", operationId: null, source: "manual", status: "completed", service: "ZELLE", customerName: "Pedro", amount: 100,
    amountCurrency: "USD", entryDate: "2026-10-07", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, missingRates: [],
  };
  const TEXT = [
    "Martes 6",
    "• Gerardo 100 Zelle (240/260)",
    "esto no tiene formato",
    "Miércoles 7",
    "• Ana 10 USDT (240/260)",
  ].join("\n");

  function fixture(overrides: Parameters<typeof createFetchMock>[0] = {}, rawText = "", entries: unknown[] = [DEL_COMPLETED, MANUAL_ROW]) {
    return createFetchMock({
      calculadoraGet: { rawText, periodo: "SEMANA 1", chatOperations: { entries } },
      ratesGet: { rates: FULL_RATES },
      ...overrides,
    });
  }
  const textarea = (node: HTMLElement) => node.querySelector("#rawText") as HTMLTextAreaElement;
  const registrarButton = (node: HTMLElement) => node.querySelector("#registrarEntradas") as HTMLButtonElement;
  async function typeText(node: HTMLElement, value: string) {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!;
    await act(async () => { setter.call(textarea(node), value); textarea(node).dispatchEvent(new Event("input", { bubbles: true })); });
  }
  const totalBoxes = (node: HTMLElement) => [...node.querySelectorAll('[data-testid="registros-totales"] td[data-label]')].map((td) => td.textContent);
  function operationsCard(node: HTMLElement) {
    return node.querySelector('[data-testid="registros-tabla"]') as HTMLElement;
  }
  const entryRows = (node: HTMLElement) => [...operationsCard(node).querySelectorAll("tbody tr[data-entry]")] as HTMLElement[];
  const cell = (row: HTMLElement, label: string) => row.querySelector(`td[data-label="${label}"]`) as HTMLElement;
  function entriesPosts(fetchMock: ReturnType<typeof createFetchMock>) {
    return calls(fetchMock, "POST", "/api/calculadora/entries").map(([, init]) => JSON.parse((init as RequestInit).body as string) as { lines: Array<Record<string, unknown>> });
  }

  it("the Auditoría card is gone, even with lines in the box that parse", async () => {
    const { node, root } = await renderPage(fixture({}, TEXT));

    expect(node.textContent).not.toContain("Auditoría");
    expect(node.textContent).not.toContain("Detalle");
    expect(node.querySelector(".legacyDayHeader")).toBeNull();
    // the box, its help and its bullet button are where they were
    expect(textarea(node).value).toBe(TEXT);
    expect(node.textContent).toContain("Registros de la semana");
    await act(async () => root.unmount());
  });

  it("the table keeps its columns and lists the manual operations next to the bot's: date, Manual mark, pencil and trash", async () => {
    const { node, root } = await renderPage(fixture());

    const headers = [...operationsCard(node).querySelectorAll("thead th")].map((th) => th.textContent);
    expect(headers).toEqual(["Día", "Cliente", "Servicio", "Monto", "Tasa", "Facturado", "Invertido", "Ganancia", "Estado", "Acciones"]);
    const [bot, manual] = entryRows(node);
    expect(cell(bot!, "Día").textContent).toBe("Sáb 12");
    expect(cell(bot!, "Día").getAttribute("title")).toBe("2026-09-12");
    expect(cell(bot!, "Servicio").textContent).toBe("Zelle");
    expect(cell(bot!, "Servicio").textContent).not.toContain("Manual");

    expect(cell(manual!, "Día").textContent).toBe("Mar 6");
    expect(cell(manual!, "Cliente").textContent).toBe("Izaa mano");
    expect(cell(manual!, "Monto").textContent).toBe("4,000 GYD");
    expect(cell(manual!, "Servicio").textContent).toContain("Trámites");
    expect(cell(manual!, "Cliente").querySelector("span")!.textContent).toBe("a mano");
    expect(cell(manual!, "Estado").textContent).toBe("Completada");
    expect(cell(manual!, "Facturado").textContent).toBe("4,000");
    expect(cell(manual!, "Ganancia").textContent).toBe("4,000");
    expect(manual!.querySelector("#editarEntry-man-iza")).not.toBeNull();
    expect(manual!.querySelector("#eliminarEntry-man-iza")).not.toBeNull();
    expect(manual!.querySelectorAll("td")).toHaveLength(10);
    await act(async () => root.unmount());
  });

  it("the totals and the service breakdown come from the entries shown; the draft text changes nothing", async () => {
    const { node, root } = await renderPage(fixture({}, TEXT));

    // 26000 + 4000, 24000 + 0, 2000 + 4000: the draft (Gerardo, Ana) is not an operation until it is registered
    expect(totalBoxes(node)).toEqual(["30,000", "24,000", "6,000"]);
    const breakdown = node.querySelector('[data-testid="semana-servicios"]')!;
    expect(breakdown.textContent).toContain("Zelle");
    expect(breakdown.textContent).toContain("Trámites");
    expect(breakdown.textContent).not.toContain("USDT");

    await typeText(node, `${TEXT}\n• Luis 1k usdt (240/260)`);
    expect(totalBoxes(node)).toEqual(["30,000", "24,000", "6,000"]);
    await act(async () => root.unmount());
  });

  it("with only a draft the totals are zero and there is no breakdown", async () => {
    const { node, root } = await renderPage(fixture({}, TEXT, []));
    expect(totalBoxes(node)).toEqual(["0", "0", "0"]);
    expect(node.querySelector('[data-testid="semana-servicios"]')).toBeNull();
    expect(node.textContent).toContain("No hay operaciones.");
    await act(async () => root.unmount());
  });

  it("the autosave saves the draft text and registers nothing", async () => {
    vi.useFakeTimers();
    const fetchMock = fixture({}, TEXT);
    const { node, root } = await renderPage(fetchMock);
    fetchMock.mockClear();

    await typeText(node, `${TEXT}\n• Luis 1k usdt (240/260)`);
    await act(async () => { await vi.advanceTimersByTimeAsync(700); });

    const saves = calls(fetchMock, "POST", "/api/calculadora").filter(([input]) => input === "/api/calculadora");
    expect(saves).toHaveLength(1);
    expect(JSON.parse((saves[0]![1] as RequestInit).body as string)).toEqual({ rawText: `${TEXT}\n• Luis 1k usdt (240/260)`, periodo: "SEMANA 1" });
    expect(entriesPosts(fetchMock)).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("opening the page does not re-save the document when nothing changed", async () => {
    vi.useFakeTimers();
    const fetchMock = fixture({}, TEXT);
    const { root } = await renderPage(fetchMock);
    fetchMock.mockClear();

    // Ninguna interacción: el autosave no debe escribir nada.
    await act(async () => { await vi.advanceTimersByTimeAsync(1200); });

    const saves = calls(fetchMock, "POST", "/api/calculadora").filter(([input]) => input === "/api/calculadora");
    expect(saves).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("Registrar is enabled only when the box holds a line that can be registered", async () => {
    const { node, root } = await renderPage(fixture());

    expect(registrarButton(node)).not.toBeNull();
    expect(registrarButton(node).textContent).toBe("Registrar");
    expect(registrarButton(node).disabled).toBe(true);
    await typeText(node, "esto no tiene formato");
    expect(registrarButton(node).disabled).toBe(true);
    await typeText(node, "• Ana 10 USDT (240/260)");
    expect(registrarButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("Registrar sends only the valid lines with their dates, takes them out of the box and keeps the line it could not read", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-07T16:00:00Z"));
    const fetchMock = fixture({}, TEXT, []);
    const { node, root } = await renderPage(fetchMock);
    expect(node.textContent).toContain('No interpretado: "esto no tiene formato"');
    fetchMock.mockClear();

    await act(async () => { registrarButton(node).click(); });
    await flush();

    expect(entriesPosts(fetchMock)).toEqual([{
      lines: [
        {
          date: "2026-10-06", dayLabel: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100, currency: "USD",
          facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "• Gerardo 100 Zelle (240/260)",
        },
        {
          date: "2026-10-07", dayLabel: "Miércoles 7", customer: "Ana", service: "USDT", amount: 10, currency: "USD",
          facturadoGyd: 2600, invertidoGyd: 2400, retornoGyd: 200, rawLine: "• Ana 10 USDT (240/260)",
        },
      ],
    }]);
    // the registered lines (and their now empty day headers) left the box; what could not be read stays, with its warning
    expect(textarea(node).value).toBe("Martes 6\nesto no tiene formato");
    expect(node.textContent).toContain('No interpretado: "esto no tiene formato"');
    // they are rows of the table now, newest day first, and they count
    const rows = entryRows(node);
    expect(rows.map((row) => cell(row, "Cliente").textContent)).toEqual(["Anaa mano", "Gerardoa mano"]);
    expect(rows.map((row) => cell(row, "Día").textContent)).toEqual(["Mié 7", "Mar 6"]);
    expect(totalBoxes(node)).toEqual(["28,600", "26,400", "2,200"]);
    expect(node.textContent).toContain("2 operaciones registradas.");
    // only the remaining text is autosaved, still without registering anything
    await act(async () => { await vi.advanceTimersByTimeAsync(700); });
    const saves = calls(fetchMock, "POST", "/api/calculadora").filter(([input]) => input === "/api/calculadora");
    expect(JSON.parse((saves.at(-1)![1] as RequestInit).body as string).rawText).toBe("Martes 6\nesto no tiene formato");
    expect(entriesPosts(fetchMock)).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("a line without a day header is dated with the Guyana day, not the UTC one", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-08T02:30:00Z")); // still the 7th in Guyana
    const fetchMock = fixture({}, "• Ana 10 USDT (240/260)", []);
    const { node, root } = await renderPage(fetchMock);

    await act(async () => { registrarButton(node).click(); });
    await flush();

    expect(entriesPosts(fetchMock)[0]!.lines[0]).toMatchObject({ date: "2026-10-07", dayLabel: null });
    expect(textarea(node).value).toBe("");
    await act(async () => root.unmount());
  });

  it("registering everything empties the box", async () => {
    const fetchMock = fixture({}, "Martes 6\n• Ana 10 USDT (240/260)\n\nMiércoles 7\n• Bea 5 USDT (240/260)", []);
    const { node, root } = await renderPage(fetchMock);

    await act(async () => { registrarButton(node).click(); });
    await flush();

    expect(textarea(node).value).toBe("");
    expect(registrarButton(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("when registering fails nothing leaves the box, the table is unchanged and an error shows", async () => {
    const fetchMock = fixture({ entriesPost: () => ({ status: 500, body: { error: "boom" } }) }, TEXT, []);
    const { node, root } = await renderPage(fetchMock);

    await act(async () => { registrarButton(node).click(); });
    await flush();

    expect(textarea(node).value).toBe(TEXT);
    expect(entryRows(node)).toHaveLength(0);
    expect(totalBoxes(node)).toEqual(["0", "0", "0"]);
    expect(node.textContent).toContain("No se pudieron registrar las operaciones; no se quitó nada del cuadro.");
    expect(registrarButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("a refused registration (no permission) says so and removes nothing", async () => {
    const fetchMock = fixture({ entriesPost: () => ({ status: 403, body: { error: "Forbidden" } }) }, TEXT, []);
    const { node, root } = await renderPage(fetchMock);

    await act(async () => { registrarButton(node).click(); });
    await flush();

    expect(textarea(node).value).toBe(TEXT);
    expect(node.textContent).toContain("No tienes permiso para registrar operaciones.");
    await act(async () => root.unmount());
  });

  it("while it registers, the button is disabled and busy and the box cannot change; a second click sends nothing", async () => {
    let release: (() => void) | undefined;
    const fetchMock = fixture({}, TEXT, []);
    const base = fetchMock.getMockImplementation()!;
    fetchMock.mockImplementation((input, init) => {
      if (input === "/api/calculadora/entries") {
        return new Promise<Response>((resolve) => {
          release = () => resolve(jsonResponse({ entries: [] }));
        });
      }
      return base(input, init);
    });
    const { node, root } = await renderPage(fetchMock);

    await act(async () => { registrarButton(node).click(); });
    expect(registrarButton(node).disabled).toBe(true);
    expect(registrarButton(node).getAttribute("aria-busy")).toBe("true");
    expect(textarea(node).readOnly).toBe(true);
    await act(async () => { registrarButton(node).click(); });
    expect(entriesPosts(fetchMock)).toHaveLength(1);

    await act(async () => { release!(); });
    await flush();
    expect(textarea(node).readOnly).toBe(false);
    await act(async () => root.unmount());
  });

  it("the old 'N líneas no se registran en Finanzas' notice is gone: what cannot be read is shown as not interpreted", async () => {
    const { node, root } = await renderPage(fixture({}, "• Raro 5 xyz\n• Ana 10 USDT (240/260)", []));

    expect(node.textContent).not.toContain("no se registra");
    expect(node.textContent).not.toContain("en Finanzas (servicio");
    expect(node.textContent).toContain('No interpretado: "• Raro 5 xyz"');
    await act(async () => root.unmount());
  });

  describe("the pencil and the trash work on a manual row exactly as on a bot row", () => {
    it("the pencil edits the figures in place and posts to the same correction route", async () => {
      const fetchMock = fixture();
      const { node, root } = await renderPage(fetchMock);

      await act(async () => { (node.querySelector("#editarEntry-man-iza") as HTMLButtonElement).click(); });
      expect(inputValue(node, "editFacturado-man-iza")).toBe("4000");
      expect(node.querySelector("#guardarEntry-man-iza")).not.toBeNull();
      expect(node.querySelector("#cancelarEntry-man-iza")).not.toBeNull();
      act(() => setInputValue(node, "editFacturado-man-iza", "5000"));
      act(() => setInputValue(node, "editInvertido-man-iza", "500"));
      await act(async () => { (node.querySelector("#guardarEntry-man-iza") as HTMLButtonElement).click(); });
      await flush();

      const posts = calls(fetchMock, "POST", "/api/calculator/entries/man-iza/correct");
      expect(posts).toHaveLength(1);
      expect(JSON.parse((posts[0]![1] as RequestInit).body as string)).toEqual({ facturadoGyd: 5000, invertidoGyd: 500 });
      const row = entryRows(node)[1]!;
      expect(cell(row, "Facturado").textContent).toBe("5,000");
      expect(cell(row, "Ganancia").textContent).toBe("4,500");
      expect(cell(row, "Cliente").textContent).toContain("a mano");
      expect(totalBoxes(node)).toEqual(["31,000", "24,500", "6,500"]);
      await act(async () => root.unmount());
    });

    it("the trash asks inline and, confirmed, posts to the same deletion route: the row leaves and the totals drop it", async () => {
      const fetchMock = fixture();
      const { node, root } = await renderPage(fetchMock);

      await act(async () => { (node.querySelector("#eliminarEntry-man-iza") as HTMLButtonElement).click(); });
      expect(entryRows(node)[1]!.textContent).toContain("¿Eliminar?");
      expect(calls(fetchMock, "POST", "/api/calculator/entries/man-iza/delete")).toHaveLength(0);
      await act(async () => { (node.querySelector("#confirmarEliminar-man-iza") as HTMLButtonElement).click(); });
      await flush();

      expect(calls(fetchMock, "POST", "/api/calculator/entries/man-iza/delete")).toHaveLength(1);
      expect(node.querySelector("#eliminarEntry-man-iza")).toBeNull();
      expect(entryRows(node)).toHaveLength(1);
      expect(totalBoxes(node)).toEqual(["26,000", "24,000", "2,000"]);
      await act(async () => root.unmount());
    });

    it("a refusal on a manual row reads like one on a bot row", async () => {
      const fetchMock = fixture({ deletePost: () => ({ status: 403, body: {} }) });
      const { node, root } = await renderPage(fetchMock);

      await act(async () => { (node.querySelector("#eliminarEntry-man-iza") as HTMLButtonElement).click(); });
      await act(async () => { (node.querySelector("#confirmarEliminar-man-iza") as HTMLButtonElement).click(); });
      await flush();

      expect(node.textContent).toContain("Solo un administrador puede eliminar esta operación.");
      expect(node.querySelector("#eliminarEntry-man-iza")).not.toBeNull();
      await act(async () => root.unmount());
    });
  });

  describe("live updates", () => {
    const live = (eventType: string, row: Record<string, unknown>) => ({
      eventType,
      new: {
        id: "man-live", operation_id: null, source: "manual", status: "completed", service: "ZELLE", customer_name: "Vivo Vicente",
        amount: "100", amount_currency: "USD", entry_date: "2026-10-06", facturado_gyd: "26000", invertido_gyd: "24000",
        retorno_gyd: "2000", missing_inputs: null, created_at: "2026-10-07T20:00:00Z", completed_at: "2026-10-06T16:00:00Z", ...row,
      },
      old: {},
    });

    it("a manual entry added elsewhere appears with its mark in date order, and leaves when it is deleted", async () => {
      const { node, root } = await renderPage(fixture({}, "", [MANUAL_ZELLE, MANUAL_ROW]));
      const chan = mockRealtime.channels[0]!;

      act(() => { chan.handler!(live("INSERT", {})); });
      const clients = () => entryRows(node).map((row) => cell(row, "Cliente").querySelector("b")!.textContent);
      expect(clients()).toEqual(["Pedro", "Vivo Vicente", "Iza"]);
      expect(cell(entryRows(node)[1]!, "Cliente").textContent).toContain("a mano");

      act(() => { chan.handler!(live("UPDATE", { status: "void" })); });
      expect(clients()).toEqual(["Pedro", "Iza"]);
      await act(async () => root.unmount());
    });

    it("the rows registered here are not duplicated when the same events arrive from the channel", async () => {
      const fetchMock = fixture({}, "• Ana 10 USDT (240/260)", []);
      const { node, root } = await renderPage(fetchMock);

      await act(async () => { registrarButton(node).click(); });
      await flush();
      act(() => { mockRealtime.channels[0]!.handler!(live("INSERT", { id: "man-1", customer_name: "Ana", entry_date: "2026-10-07" })); });

      expect(entryRows(node)).toHaveLength(1);
      await act(async () => root.unmount());
    });
  });

  describe("Limpiar Todo and Semanas anteriores", () => {
    function clearButton(node: HTMLElement) {
      return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.includes("Limpiar Todo")) as HTMLButtonElement;
    }
    async function confirmCut(node: HTMLElement) {
      await act(async () => { clearButton(node).click(); });
      await act(async () => { (Array.from(document.querySelectorAll("[role=dialog] button")).find((b) => b.textContent?.trim() === "Limpiar todo") as HTMLButtonElement).click(); });
      await flush();
    }

    it("the cut sends the draft text and the period only, and the week's manual rows leave the table with the bot's", async () => {
      const fetchMock = fixture({}, "• Pendiente de registrar 5 xyz");
      const { node, root } = await renderPage(fetchMock);
      fetchMock.mockClear();

      await confirmCut(node);

      const cut = calls(fetchMock, "POST", "/api/calculadora/weeks");
      expect(cut).toHaveLength(1);
      expect(JSON.parse((cut[0]![1] as RequestInit).body as string)).toEqual({ rawText: "• Pendiente de registrar 5 xyz", periodo: "SEMANA 1" });
      expect(entryRows(node)).toHaveLength(0);
      expect(totalBoxes(node)).toEqual(["0", "0", "0"]);
      // the emptied week saves an empty text and registers nothing
      expect(entriesPosts(fetchMock)).toHaveLength(0);
      await act(async () => root.unmount());
    });
  });

  describe("the text export", () => {
    async function exported(node: HTMLElement) {
      const blobs: Blob[] = [];
      Object.defineProperty(URL, "createObjectURL", { configurable: true, writable: true, value: (blob: Blob) => { blobs.push(blob); return "blob:test"; } });
      Object.defineProperty(URL, "revokeObjectURL", { configurable: true, writable: true, value: () => {} });
      vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
      const button = Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.includes("Exportar Reporte")) as HTMLButtonElement;
      await act(async () => { button.click(); });
      return new Promise<string>((resolve) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result));
        reader.readAsText(blobs[0]!);
      });
    }

    it("lists every operation of the table with its date and a manual mark, and leaves out an empty draft", async () => {
      const { node, root } = await renderPage(fixture());

      const text = await exported(node);

      expect(text).toContain("TOTAL FACTURADO (GYD): 30000.00");
      expect(text).toContain("=== OPERACIONES ===");
      expect(text).toContain("• 2026-09-12 Raúl 100 ZELLE [completed]");
      expect(text).toContain("• 2026-10-06 Iza 4000 GYD (manual) [completed]");
      expect(text).not.toContain("REGISTRO MANUAL EN BRUTO");
      await act(async () => root.unmount());
    });

    it("keeps the raw draft section while text remains in the box", async () => {
      const { node, root } = await renderPage(fixture({}, "esto no tiene formato"));

      const text = await exported(node);

      expect(text).toContain("=== REGISTRO MANUAL EN BRUTO (SIN REGISTRAR) ===\nesto no tiene formato");
      await act(async () => root.unmount());
    });
  });
});

// Step 1 of the semantic money colours (odd/tasks/semantic-money-colors.md): facturado is blue, invertido amber,
// the result green or red with a sign. Only the three money columns and the totals carry a tone.
describe("calculator money tones", () => {
  const LOSS = {
    id: "loss-1", operationId: null, source: "manual", status: "completed", service: "DIRECTO", customerName: "Pérdida", amount: 500,
    amountCurrency: "GYD", entryDate: "2026-10-06", facturadoGyd: 500, invertidoGyd: 1000, retornoGyd: -500, missingRates: [],
  };
  const WEEK = {
    id: "week-1", cutAt: "2026-10-03T12:00:00+00:00", periodo: "SEMANA 1", rawText: "",
    manualTotals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 },
    chatTotals: { count: 1, facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 },
    entries: [{ ...DEL_COMPLETED, id: "arch-1" }],
  };
  function fixture(entries: unknown[]) {
    return createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", chatOperations: { entries } },
      ratesGet: { rates: null },
      weeksGet: { weeks: [WEEK] },
      weekGet: () => ({ status: 200, body: { week: WEEK } }),
    });
  }
  const totalCells = (root: ParentNode) => [...root.querySelectorAll('[data-testid="registros-totales"] td[data-label]')] as HTMLElement[];
  const tones = (root: ParentNode) => totalCells(root).map((el) => el.dataset.tone ?? "neutral");
  const operationsCard = (node: HTMLElement) => node.querySelector('[data-testid="registros-tabla"]') as HTMLElement;
  const toneOf = (row: Element, label: string) => row.querySelector(`td[data-label="${label}"]`)?.getAttribute("data-tone") ?? null;

  it("colours the totals of the table blue / amber / green by what each stands for", async () => {
    const { node, root } = await renderPage(fixture([DEL_COMPLETED]));

    expect(tones(node)).toEqual(["in", "out", "profit"]);
    expect(totalCells(node).map((f) => f.className)).toEqual([
      expect.stringContaining("text-money-in"), expect.stringContaining("text-money-out"), expect.stringContaining("text-money-profit"),
    ]);
    await act(async () => root.unmount());
  });

  it("shows a negative result in red with a minus sign, and a zero result neutral", async () => {
    const loss = await renderPage(fixture([LOSS]));
    expect(tones(loss.node)).toEqual(["in", "out", "loss"]);
    expect(totalCells(loss.node)[2]!.textContent).toBe("-500");
    await act(async () => loss.root.unmount());

    const empty = await renderPage(fixture([]));
    expect(tones(empty.node)).toEqual(["in", "out", "neutral"]);
    expect(totalCells(empty.node)[2]!.textContent).toBe("0");
    await act(async () => empty.root.unmount());
  });

  it("tones only the Facturado / Invertido / Ganancia cells of the records table", async () => {
    const { node, root } = await renderPage(fixture([DEL_COMPLETED, LOSS, DEL_PENDING]));

    const [ok, loss, pending] = [...operationsCard(node).querySelectorAll("tbody tr[data-entry]")];
    expect([toneOf(ok!, "Facturado"), toneOf(ok!, "Invertido"), toneOf(ok!, "Ganancia")]).toEqual(["in", "out", "profit"]);
    expect(toneOf(loss!, "Ganancia")).toBe("loss");
    // a missing figure is a plain dash
    expect([toneOf(pending!, "Facturado"), toneOf(pending!, "Invertido"), toneOf(pending!, "Ganancia")]).toEqual([null, null, null]);
    for (const label of ["Día", "Cliente", "Monto", "Servicio", "Estado"]) expect(toneOf(ok!, label)).toBeNull();
    // table figures are not signed
    expect(ok!.querySelector('td[data-label="Ganancia"]')!.textContent).toBe("2,000");
    await act(async () => root.unmount());
  });

  // Step 2 and the step 1 leftovers (odd/tasks/semantic-money-colors.md, T7-T9).
  it("puts the fixed service dot before the service name in the operations table, and nowhere else in the row", async () => {
    const { node, root } = await renderPage(fixture([DEL_COMPLETED, LOSS]));

    const [zelle, directo] = [...operationsCard(node).querySelectorAll("tbody tr[data-entry]")];
    const dotOf = (row: Element) => row.querySelector('td[data-label="Servicio"] [data-service]') as HTMLElement | null;
    expect(dotOf(zelle!)?.dataset.service).toBe("zelle");
    expect(dotOf(zelle!)?.getAttribute("aria-hidden")).toBe("true");
    expect(dotOf(zelle!)?.className).toContain("bg-service-zelle");
    expect(dotOf(directo!)?.dataset.service).toBe("directo");
    expect(zelle!.querySelector('td[data-label="Servicio"]')!.textContent).toBe("Zelle");
    expect(zelle!.querySelectorAll("[data-service]")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("replaces the old per-service breakdown with the clickable 'De dónde sale la ganancia' list", async () => {
    const { node, root } = await renderPage(fixture([DEL_COMPLETED, LOSS]));

    expect(node.textContent).not.toContain("Desglose Semanal por Servicios");
    expect(node.querySelector(".legacyBlockRow")).toBeNull();
    const rows = [...node.querySelectorAll('[data-testid="semana-servicios"] button')].map((b) => b.textContent);
    expect(rows).toHaveLength(2);
    expect(rows[0]).toContain("Zelle");
    expect(rows[1]).toContain("Trámites");
    await act(async () => root.unmount());
  });
});

describe("calculator shows no emojis", () => {
  const EMOJI = /\p{Extended_Pictographic}/u;
  const SUMMARY = {
    id: "week-1", cutAt: "2026-10-03T12:00:00+00:00", periodo: "SEMANA 1",
    manualTotals: { facturadoGyd: 1000, invertidoGyd: 800, retornoGyd: 200 },
    chatTotals: { count: 1, facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 },
  };
  const MANUAL_ROW = {
    id: "man-iza", operationId: null, source: "manual", status: "completed", service: "DIRECTO", customerName: "Iza", amount: 4000,
    amountCurrency: "GYD", entryDate: "2026-10-06", facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000, missingRates: [],
  };
  const TEXT = "Martes 6\n• Gerardo 100 Zelle (240/260)\nesto no tiene formato";

  function fixture(rawText: string, entries: unknown[], overrides: Parameters<typeof createFetchMock>[0] = {}) {
    return createFetchMock({
      calculadoraGet: { rawText, periodo: "SEMANA 1", chatOperations: { entries } },
      ratesGet: { rates: FULL_RATES },
      weeksGet: { weeks: [SUMMARY] },
      weekGet: () => ({ status: 200, body: { week: { ...SUMMARY, rawText: "• Fran 50k CUP (235/980)", entries: [{ ...DEL_COMPLETED, id: "arch-1" }] } } }),
      ...overrides,
    });
  }

  it("the open week with bot and manual rows, an uninterpreted line and the format guide", async () => {
    const { node, root } = await renderPage(fixture(TEXT, [DEL_COMPLETED, MANUAL_ROW]));
    expect(node.textContent).toContain("Registros de la semana");
    expect(node.textContent).toContain("No interpretado");
    expect(node.textContent).not.toMatch(EMOJI);
    await act(async () => root.unmount());
  });

  it("an empty Calculator", async () => {
    const { node, root } = await renderPage(fixture("", []));
    expect(node.textContent).not.toMatch(EMOJI);
    await act(async () => root.unmount());
  });

  it("the Limpiar Todo dialog", async () => {
    const { node, root } = await renderPage(fixture(TEXT, [DEL_COMPLETED]));
    const clear = Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.includes("Limpiar Todo")) as HTMLButtonElement;
    await act(async () => { clear.click(); });
    expect(document.querySelector("[role=dialog]")).not.toBeNull();
    expect(document.body.textContent).not.toMatch(EMOJI);
    await act(async () => root.unmount());
  });
});

describe("calculator chat operations (investment rates of one entry)", () => {
  const CUP_ENTRY = {
    id: "entry-cup",
    operationId: "op-cup",
    source: "completed_operation",
    status: "completed",
    service: "CUP",
    customerName: "Yaima",
    amount: 106000,
    amountCurrency: "CUP",
    entryDate: "2026-10-14",
    facturadoGyd: 35000,
    invertidoGyd: 20500,
    retornoGyd: 14500,
    missingRates: [],
    cupGlobalRate: 3,
    cupRate: 1060,
    usdtBuyGyd: 205,
    usdtSellGyd: 215,
    costGyd: null,
    basisGyd: 106000,
    saleGyd: null,
  };
  const ZELLE_ENTRY = {
    ...CUP_ENTRY,
    id: "entry-zelle",
    service: "ZELLE",
    amount: 100,
    amountCurrency: "USD",
    facturadoGyd: 21500,
    invertidoGyd: 20500,
    retornoGyd: 1000,
    cupRate: 1060,
  };
  const COMBO_ENTRY = {
    ...CUP_ENTRY,
    id: "entry-combo",
    service: "COMBO",
    cupGlobalRate: null,
    cupRate: null,
    usdtBuyGyd: null,
    usdtSellGyd: null,
  };

  function fixture(overrides?: Parameters<typeof createFetchMock>[0]) {
    return createFetchMock({
      calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [CUP_ENTRY, ZELLE_ENTRY, COMBO_ENTRY] } },
      ratesGet: { rates: null },
      ...overrides,
    });
  }

  async function openEditor(node: HTMLElement, entryId: string) {
    const editButton = node.querySelector(`#editarEntry-${entryId}`) as HTMLButtonElement;
    await act(async () => { editButton.click(); });
  }

  async function save(node: HTMLElement, entryId: string) {
    const saveButton = node.querySelector(`#guardarEntry-${entryId}`) as HTMLButtonElement;
    await act(async () => { saveButton.click(); });
    await flush();
  }

  function callsTo(fetchMock: ReturnType<typeof createFetchMock>, url: string) {
    return fetchMock.mock.calls.filter(([input]) => (typeof input === "string" ? input : input.toString()) === url);
  }

  it("shows the rates the entry was costed with and edits both investment rates of a CUP entry", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "entry-cup");

    expect(inputValue(node, "editCompraUsdt-entry-cup")).toBe("205");
    expect(inputValue(node, "editVentaUsdtCup-entry-cup")).toBe("1060");
    const rates = node.querySelector("#tasasEntry-entry-cup") as HTMLElement;
    expect(rates.textContent).toContain("Tarifa CUP");
    expect(rates.textContent).toContain("3");
    expect(rates.textContent).toContain("215");
    await act(async () => root.unmount());
  });

  it("a non-CUP entry edits only Compra USDT (GYD)", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "entry-zelle");

    expect(inputValue(node, "editCompraUsdt-entry-zelle")).toBe("205");
    expect(node.querySelector("#editVentaUsdtCup-entry-zelle")).toBeNull();
    await act(async () => root.unmount());
  });

  it("an entry without rates (COMBO) shows no rate editor", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "entry-combo");

    expect(node.querySelector("#tasasEntry-entry-combo")).toBeNull();
    expect(node.querySelector("#editCompraUsdt-entry-combo")).toBeNull();
    await act(async () => root.unmount());
  });

  it("previews the recomputed invertido and ganancia while the rate is typed, without any network call", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "entry-cup");
    fetchMock.mockClear();

    act(() => setInputValue(node, "editVentaUsdtCup-entry-cup", "960"));

    const expectedInvertido = (106000 / 960) * 205;
    expect(inputValue(node, "editInvertido-entry-cup")).toBe(expectedInvertido.toFixed(2));
    expect(isInputDisabled(node, "editInvertido-entry-cup")).toBe(true);
    expect(node.textContent).toContain(num(35000 - Number(expectedInvertido.toFixed(2)), 2));
    expect(fetchMock).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("saving a changed rate calls the rates route only and shows the stored figures and rates", async () => {
    const fetchMock = fixture({
      ratesEntryPost: (entryId) => ({
        status: 200,
        body: {
          entry: {
            id: entryId, status: "completed", facturadoGyd: 35000, invertidoGyd: 22000, retornoGyd: 13000,
            cupGlobalRate: 3, cupRate: 960, usdtBuyGyd: 205, usdtSellGyd: 215, costGyd: null, basisGyd: 106000, saleGyd: null,
          },
        },
      }),
    });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "entry-cup");
    act(() => setInputValue(node, "editVentaUsdtCup-entry-cup", "960"));
    await save(node, "entry-cup");

    const ratesCalls = callsTo(fetchMock, "/api/calculator/entries/entry-cup/rates");
    expect(ratesCalls).toHaveLength(1);
    expect(JSON.parse((ratesCalls[0]![1] as RequestInit).body as string)).toEqual({ cupRate: 960 });
    expect(callsTo(fetchMock, "/api/calculator/entries/entry-cup/correct")).toHaveLength(0);
    expect(node.querySelector("#guardarEntry-entry-cup")).toBeNull();
    expect(node.textContent).toContain(num(22000, 2));
    await openEditor(node, "entry-cup");
    expect(inputValue(node, "editVentaUsdtCup-entry-cup")).toBe("960");
    await act(async () => root.unmount());
  });

  it("an unchanged rate never calls the rates route: the figures edit keeps working as before", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "entry-zelle");
    act(() => setInputValue(node, "editFacturado-entry-zelle", "22000"));
    act(() => setInputValue(node, "editInvertido-entry-zelle", "20000"));
    await save(node, "entry-zelle");

    expect(callsTo(fetchMock, "/api/calculator/entries/entry-zelle/rates")).toHaveLength(0);
    const correct = callsTo(fetchMock, "/api/calculator/entries/entry-zelle/correct");
    expect(correct).toHaveLength(1);
    expect(JSON.parse((correct[0]![1] as RequestInit).body as string)).toEqual({ facturadoGyd: 22000, invertidoGyd: 20000 });
    await act(async () => root.unmount());
  });

  it("a changed rate plus a changed facturado saves the rates first, then corrects the facturado over the stored invertido", async () => {
    const fetchMock = fixture({
      ratesEntryPost: (entryId) => ({
        status: 200,
        body: {
          entry: {
            id: entryId, status: "completed", facturadoGyd: 21500, invertidoGyd: 19000, retornoGyd: 2500,
            cupGlobalRate: 3, cupRate: 1060, usdtBuyGyd: 190, usdtSellGyd: 215, costGyd: null, basisGyd: 106000, saleGyd: null,
          },
        },
      }),
    });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "entry-zelle");
    act(() => setInputValue(node, "editCompraUsdt-entry-zelle", "190"));
    act(() => setInputValue(node, "editFacturado-entry-zelle", "22000"));
    await save(node, "entry-zelle");

    expect(callsTo(fetchMock, "/api/calculator/entries/entry-zelle/rates")).toHaveLength(1);
    const correct = callsTo(fetchMock, "/api/calculator/entries/entry-zelle/correct");
    expect(correct).toHaveLength(1);
    expect(JSON.parse((correct[0]![1] as RequestInit).body as string)).toEqual({ facturadoGyd: 22000, invertidoGyd: 19000 });
    expect(node.querySelector("#guardarEntry-entry-zelle")).toBeNull();
    await act(async () => root.unmount());
  });

  it("a refused rates save (400) shows the server message and keeps the editor open", async () => {
    const fetchMock = fixture({
      ratesEntryPost: () => ({ status: 400, body: { error: "entry belongs to an archived week and cannot be corrected" } }),
    });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "entry-cup");
    act(() => setInputValue(node, "editVentaUsdtCup-entry-cup", "960"));
    await save(node, "entry-cup");

    expect(node.textContent).toContain("entry belongs to an archived week and cannot be corrected");
    expect(node.querySelector("#guardarEntry-entry-cup")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("rejects a non-positive rate client-side without a network call", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "entry-cup");
    act(() => setInputValue(node, "editVentaUsdtCup-entry-cup", "0"));
    fetchMock.mockClear();
    await save(node, "entry-cup");

    expect(fetchMock).not.toHaveBeenCalled();
    expect(node.textContent).toContain("mayores que 0");
    expect(node.querySelector("#guardarEntry-entry-cup")).not.toBeNull();
    await act(async () => root.unmount());
  });
});

describe("calculator manual entries (investment rates, migration 237)", () => {
  // As production holds them: typed figures, no snapshot at all.
  const MANUAL_CUP = {
    id: "man-cup", operationId: null, source: "manual", status: "completed", service: "CUP", customerName: "Yaima", amount: 15000,
    amountCurrency: "CUP", entryDate: "2026-10-14", facturadoGyd: 5000, invertidoGyd: 3750, retornoGyd: 1250, missingRates: [],
  };
  const MANUAL_ZELLE = { ...MANUAL_CUP, id: "man-zelle", service: "ZELLE", amount: 100, amountCurrency: "USD", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 };
  const MANUAL_RECARGA = { ...MANUAL_CUP, id: "man-rec", service: "RECARGA", amount: 2, amountCurrency: "REC" };

  function fixture(overrides?: Parameters<typeof createFetchMock>[0]) {
    return createFetchMock({
      calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [MANUAL_CUP, MANUAL_ZELLE, MANUAL_RECARGA] } },
      ratesGet: { rates: FULL_RATES },
      ...overrides,
    });
  }
  async function openEditor(node: HTMLElement, entryId: string) {
    await act(async () => { (node.querySelector(`#editarEntry-${entryId}`) as HTMLButtonElement).click(); });
  }
  async function save(node: HTMLElement, entryId: string) {
    await act(async () => { (node.querySelector(`#guardarEntry-${entryId}`) as HTMLButtonElement).click(); });
    await flush();
  }
  const callsTo = (fetchMock: ReturnType<typeof createFetchMock>, url: string) =>
    fetchMock.mock.calls.filter(([input]) => (typeof input === "string" ? input : input.toString()) === url);

  it("Editar on a manual row prefills the rates with the CURRENT global investment rates", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "man-cup");
    expect(inputValue(node, "editCompraUsdt-man-cup")).toBe(String(FULL_RATES.usdtBuyGyd));
    expect(inputValue(node, "editVentaUsdtCup-man-cup")).toBe(String(FULL_RATES.usdtSellCup));
    await openEditor(node, "man-zelle");
    expect(inputValue(node, "editCompraUsdt-man-zelle")).toBe(String(FULL_RATES.usdtBuyGyd));
    expect(node.querySelector("#editVentaUsdtCup-man-zelle")).toBeNull();
    await act(async () => root.unmount());
  });

  describe("a manual row shows the rates its typed line was quoted with (production-shaped lines)", () => {
    const LINE_CUP = { ...MANUAL_CUP, id: "line-cup", amount: 15000, rawLine: "• Marlene 15,000 cup (240/960)" };
    const LINE_ZELLE = { ...MANUAL_ZELLE, id: "line-zelle", amount: 50, rawLine: "• Michel 50 Zelle (238/260)", facturadoGyd: 13000, invertidoGyd: 11900, retornoGyd: 1100 };
    const LINE_CLASICA = {
      ...MANUAL_ZELLE, id: "line-clasica", service: "CLASICA", amount: 76, rawLine: "• Zulemys 76 Clásica (3%/238/260)",
      facturadoGyd: 19760, invertidoGyd: 17561.17, retornoGyd: 2198.83,
    };
    const lineFixture = (overrides?: Parameters<typeof createFetchMock>[0]) =>
      createFetchMock({
        calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [LINE_CUP, LINE_ZELLE, LINE_CLASICA] } },
        ratesGet: { rates: FULL_RATES },
        ...overrides,
      });

    it("prefills from the line, not from the current global rates", async () => {
      const { node, root } = await renderPage(lineFixture());
      await openEditor(node, "line-cup");
      expect(inputValue(node, "editCompraUsdt-line-cup")).toBe("240");
      expect(inputValue(node, "editVentaUsdtCup-line-cup")).toBe("960");
      await openEditor(node, "line-zelle");
      expect(inputValue(node, "editCompraUsdt-line-zelle")).toBe("238");
      await openEditor(node, "line-clasica");
      expect(inputValue(node, "editCompraUsdt-line-clasica")).toBe("238");
      await act(async () => root.unmount());
    });

    it("a discounted line previews amount / (1 + pct / 100) * buy and saves the buy rate", async () => {
      const fetchMock = lineFixture({
        ratesEntryPost: (entryId) => ({
          status: 200,
          body: { entry: { id: entryId, status: "completed", facturadoGyd: 19760, invertidoGyd: (76 / 1.03) * 230, retornoGyd: 19760 - (76 / 1.03) * 230, cupGlobalRate: null, cupRate: null, usdtBuyGyd: 230, usdtSellGyd: null, costGyd: null, basisGyd: null, saleGyd: null } },
        }),
      });
      const { node, root } = await renderPage(fetchMock);
      await openEditor(node, "line-clasica");
      act(() => setInputValue(node, "editCompraUsdt-line-clasica", "230"));
      expect(inputValue(node, "editInvertido-line-clasica")).toBe(((76 / 1.03) * 230).toFixed(2));
      await save(node, "line-clasica");
      const calls = callsTo(fetchMock, "/api/calculator/entries/line-clasica/rates");
      expect(calls).toHaveLength(1);
      expect(JSON.parse((calls[0]![1] as RequestInit).body as string)).toEqual({ usdtBuyGyd: 230 });
      await act(async () => root.unmount());
    });

    it("leaving the line's own rates alone does not call the rates route", async () => {
      const fetchMock = lineFixture();
      const { node, root } = await renderPage(fetchMock);
      await openEditor(node, "line-zelle");
      act(() => setInputValue(node, "editFacturado-line-zelle", "13100"));
      await save(node, "line-zelle");
      expect(callsTo(fetchMock, "/api/calculator/entries/line-zelle/rates")).toHaveLength(0);
      expect(callsTo(fetchMock, "/api/calculator/entries/line-zelle/correct")).toHaveLength(1);
      await act(async () => root.unmount());
    });

    it("once rates are stored on the row, the stored ones win over the line", async () => {
      const stored = { ...LINE_ZELLE, id: "stored-zelle", usdtBuyGyd: 236, cupRate: null };
      const { node, root } = await renderPage(
        createFetchMock({ calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [stored] } }, ratesGet: { rates: FULL_RATES } }),
      );
      await openEditor(node, "stored-zelle");
      expect(inputValue(node, "editCompraUsdt-stored-zelle")).toBe("236");
      await act(async () => root.unmount());
    });

    it("a line without rates falls back to the current global rates", async () => {
      const bare = { ...MANUAL_ZELLE, id: "bare", rawLine: "• Iza 100 Zelle" };
      const { node, root } = await renderPage(
        createFetchMock({ calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [bare] } }, ratesGet: { rates: FULL_RATES } }),
      );
      await openEditor(node, "bare");
      expect(inputValue(node, "editCompraUsdt-bare")).toBe(String(FULL_RATES.usdtBuyGyd));
      await act(async () => root.unmount());
    });
  });

  it("a manual RECARGA whose line carries no cost shows the cost field empty (migration 242)", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "man-rec");
    expect(node.querySelector("#tasasEntry-man-rec")).not.toBeNull();
    expect(inputValue(node, "editCostoUsdt-man-rec")).toBe("");
    expect(inputValue(node, "editCompraUsdt-man-rec")).toBe(String(FULL_RATES.usdtBuyGyd));
    await act(async () => root.unmount());
  });

  it("changing a rate previews the recomputed invertido and saving sends BOTH rates the formula needs", async () => {
    const fetchMock = fixture({
      ratesEntryPost: (entryId) => ({
        status: 200,
        body: { entry: { id: entryId, status: "completed", facturadoGyd: 5000, invertidoGyd: 3750, retornoGyd: 1250, cupGlobalRate: null, cupRate: 960, usdtBuyGyd: FULL_RATES.usdtBuyGyd, usdtSellGyd: null, costGyd: null, basisGyd: null, saleGyd: null } },
      }),
    });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "man-cup");
    act(() => setInputValue(node, "editVentaUsdtCup-man-cup", "960"));
    expect(inputValue(node, "editInvertido-man-cup")).toBe(((15000 / 960) * FULL_RATES.usdtBuyGyd).toFixed(2));
    await save(node, "man-cup");

    const calls = callsTo(fetchMock, "/api/calculator/entries/man-cup/rates");
    expect(calls).toHaveLength(1);
    expect(JSON.parse((calls[0]![1] as RequestInit).body as string)).toEqual({ usdtBuyGyd: FULL_RATES.usdtBuyGyd, cupRate: 960 });
    await openEditor(node, "man-cup");
    expect(inputValue(node, "editVentaUsdtCup-man-cup")).toBe("960");
    await act(async () => root.unmount());
  });

  it("leaving the prefilled rates alone keeps the figures edit working and never calls the rates route", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "man-zelle");
    act(() => setInputValue(node, "editFacturado-man-zelle", "27000"));
    await save(node, "man-zelle");

    expect(callsTo(fetchMock, "/api/calculator/entries/man-zelle/rates")).toHaveLength(0);
    const correct = callsTo(fetchMock, "/api/calculator/entries/man-zelle/correct");
    expect(correct).toHaveLength(1);
    expect(JSON.parse((correct[0]![1] as RequestInit).body as string)).toEqual({ facturadoGyd: 27000, invertidoGyd: 24000 });
    await act(async () => root.unmount());
  });

  it("without global rates loaded the fields start empty and the figures edit is not blocked", async () => {
    const fetchMock = fixture({ ratesGet: { rates: null } });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "man-cup");
    expect(inputValue(node, "editCompraUsdt-man-cup")).toBe("");
    act(() => setInputValue(node, "editFacturado-man-cup", "5100"));
    await save(node, "man-cup");
    expect(callsTo(fetchMock, "/api/calculator/entries/man-cup/rates")).toHaveLength(0);
    expect(callsTo(fetchMock, "/api/calculator/entries/man-cup/correct")).toHaveLength(1);
    await act(async () => root.unmount());
  });
});


describe("per-operation cost of a recharge or saldo entry (migration 242)", () => {
  const REC_ENTRY = {
    id: "rec-500", operationId: "op-rec", source: "completed_operation", status: "completed", service: "RECARGA", customerName: "Josefa",
    amount: 1, amountCurrency: "REC", entryDate: "2026-10-17", facturadoGyd: 5200, invertidoGyd: 4680, retornoGyd: 520, missingRates: [],
    cupGlobalRate: 3, cupRate: 240, usdtBuyGyd: 240, usdtSellGyd: 5200, costGyd: 19.5, basisGyd: 5200, saleGyd: 5200,
  };
  const SALDO_ENTRY = {
    ...REC_ENTRY, id: "saldo-1", operationId: "op-saldo", service: "SALDO_MOVIL", customerName: "Carlos", amount: 1080, amountCurrency: "SM",
    facturadoGyd: 3000, invertidoGyd: 1440, retornoGyd: 1560, usdtSellGyd: 1000, costGyd: 2, basisGyd: 3000, saleGyd: 1000,
  };
  const MANUAL_REC = {
    id: "man-line", operationId: null, source: "manual", status: "completed", service: "RECARGA", customerName: "Onaisy", amount: 1,
    amountCurrency: "REC", entryDate: "2026-10-17", facturadoGyd: 6200, invertidoGyd: 5544, retornoGyd: 656, missingRates: [],
    rawLine: "• Onaisy 1 rec promo(23.1/6.2k/240)",
  };

  function fixture(overrides?: Parameters<typeof createFetchMock>[0]) {
    return createFetchMock({
      calculadoraGet: { rawText: "", periodo: "SEMANA 1", chatOperations: { entries: [REC_ENTRY, SALDO_ENTRY, MANUAL_REC] } },
      ratesGet: { rates: FULL_RATES },
      ...overrides,
    });
  }
  async function openEditor(node: HTMLElement, entryId: string) {
    await act(async () => { (node.querySelector(`#editarEntry-${entryId}`) as HTMLButtonElement).click(); });
  }
  async function save(node: HTMLElement, entryId: string) {
    await act(async () => { (node.querySelector(`#guardarEntry-${entryId}`) as HTMLButtonElement).click(); });
    await flush();
  }
  const callsTo = (fetchMock: ReturnType<typeof createFetchMock>, url: string) =>
    fetchMock.mock.calls.filter(([input]) => (typeof input === "string" ? input : input.toString()) === url);
  const labelOf = (node: HTMLElement, id: string) => node.querySelector(`label[for="${id}"]`)?.textContent ?? "";

  it("a chat recharge shows 'Costo por recarga (USDT)' and Compra USDT (GYD), prefilled from the entry snapshot", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "rec-500");
    expect(labelOf(node, "editCostoUsdt-rec-500")).toContain("Costo por recarga (USDT)");
    expect(inputValue(node, "editCostoUsdt-rec-500")).toBe("19.5");
    expect(inputValue(node, "editCompraUsdt-rec-500")).toBe("240");
    expect(node.querySelector("#editVentaUsdtCup-rec-500")).toBeNull();
    await act(async () => root.unmount());
  });

  it("a saldo entry labels the cost per 360 CUP", async () => {
    const { node, root } = await renderPage(fixture());
    await openEditor(node, "saldo-1");
    expect(labelOf(node, "editCostoUsdt-saldo-1")).toContain("Costo por 360 CUP (USDT)");
    expect(inputValue(node, "editCostoUsdt-saldo-1")).toBe("2");
    await act(async () => root.unmount());
  });

  it("previews invertido and ganancia while the cost is typed (saldo 1.6 -> 1,152 and 1,848), with no network call", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "saldo-1");
    fetchMock.mockClear();
    act(() => setInputValue(node, "editCostoUsdt-saldo-1", "1.6"));
    expect(inputValue(node, "editInvertido-saldo-1")).toBe("1152.00");
    expect(node.textContent).toContain(num(1848, 2));
    expect(fetchMock).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("saving a changed cost posts costoUsdt only to the rates route", async () => {
    const fetchMock = fixture({
      ratesEntryPost: (entryId) => ({
        status: 200,
        body: { entry: { id: entryId, status: "completed", facturadoGyd: 5200, invertidoGyd: 4560, retornoGyd: 640, cupGlobalRate: 3, cupRate: 240, usdtBuyGyd: 240, usdtSellGyd: 5200, costGyd: 19, basisGyd: 5200, saleGyd: 5200 } },
      }),
    });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "rec-500");
    act(() => setInputValue(node, "editCostoUsdt-rec-500", "19"));
    expect(inputValue(node, "editInvertido-rec-500")).toBe("4560.00");
    await save(node, "rec-500");
    const calls = callsTo(fetchMock, "/api/calculator/entries/rec-500/rates");
    expect(calls).toHaveLength(1);
    expect(JSON.parse((calls[0]![1] as RequestInit).body as string)).toEqual({ costoUsdt: 19 });
    expect(callsTo(fetchMock, "/api/calculator/entries/rec-500/correct")).toHaveLength(0);
    await openEditor(node, "rec-500");
    expect(inputValue(node, "editCostoUsdt-rec-500")).toBe("19");
    await act(async () => root.unmount());
  });

  it("a manual recharge line is prefilled from its typed line and a change sends the cost AND the buy rate", async () => {
    const fetchMock = fixture({
      ratesEntryPost: (entryId) => ({
        status: 200,
        body: { entry: { id: entryId, status: "completed", facturadoGyd: 6200, invertidoGyd: 5472, retornoGyd: 728, cupGlobalRate: null, cupRate: 240, usdtBuyGyd: 240, usdtSellGyd: null, costGyd: 22.8, basisGyd: null, saleGyd: null } },
      }),
    });
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "man-line");
    expect(inputValue(node, "editCostoUsdt-man-line")).toBe("23.1");
    expect(inputValue(node, "editCompraUsdt-man-line")).toBe("240");
    act(() => setInputValue(node, "editCostoUsdt-man-line", "22.8"));
    expect(inputValue(node, "editInvertido-man-line")).toBe("5472.00");
    await save(node, "man-line");
    const calls = callsTo(fetchMock, "/api/calculator/entries/man-line/rates");
    expect(calls).toHaveLength(1);
    expect(JSON.parse((calls[0]![1] as RequestInit).body as string)).toEqual({ costoUsdt: 22.8, usdtBuyGyd: 240 });
    await act(async () => root.unmount());
  });

  it("an unchanged cost never calls the rates route", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "rec-500");
    act(() => setInputValue(node, "editFacturado-rec-500", "5300"));
    await save(node, "rec-500");
    expect(callsTo(fetchMock, "/api/calculator/entries/rec-500/rates")).toHaveLength(0);
    expect(callsTo(fetchMock, "/api/calculator/entries/rec-500/correct")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("a cost that is not above zero is rejected client-side", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);
    await openEditor(node, "rec-500");
    act(() => setInputValue(node, "editCostoUsdt-rec-500", "0"));
    fetchMock.mockClear();
    await save(node, "rec-500");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(node.textContent).toContain("mayores que 0");
    await act(async () => root.unmount());
  });
});

describe("calculator ARQ USD to MXN rate (Tasas actuales)", () => {
  it("shows the ARQ bid as the main figure with ask and age, after the editable rates", async () => {
    const { node, root } = await renderPage(createFetchMock({
      ratesGet: {
        rates: FULL_RATES,
        arqRate: { valor: 18.647481, fuente: "arq", edad_min: 2, ask: "18.6697421235", bid: "18.6474810965", fecha_arq: "2026-10-24T15:09:31Z" },
      },
    }));

    const row = node.querySelector("#tasaMexicoArq");
    expect(row?.textContent).toContain("USD → MXN · auto, hace 2 min");
    expect(row?.textContent).toContain("18.647481");
    expect(row?.textContent).toContain("ask 18.669742");
    expect(row?.textContent).toContain("hace 2 min");
    expect(row?.textContent).not.toContain("sin actualizar");
    await act(async () => root.unmount());
  });

  it("marks a stale rate instead of pretending it is fresh", async () => {
    const { node, root } = await renderPage(createFetchMock({
      ratesGet: {
        rates: FULL_RATES,
        arqRate: { valor: 18.647481, fuente: "arq", edad_min: 180, ask: "18.6697421235" },
      },
    }));

    expect(node.querySelector("#tasaMexicoArq")?.textContent).toContain("sin actualizar desde hace 3 h");
    await act(async () => root.unmount());
  });

  it("renders no ARQ row when the database has no rate yet", async () => {
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES } }));

    expect(node.querySelector("#tasaMexicoArq")).toBeNull();
    await act(async () => root.unmount());
  });
});

describe("calculator ARQ rate failure indicator", () => {
  it("warns when the last ARQ attempt failed even if a fallback value is fresh", async () => {
    const { node, root } = await renderPage(createFetchMock({
      ratesGet: {
        rates: FULL_RATES,
        arqRate: {
          valor: 18.69233, fuente: "erapi", edad_min: 5, ask: null, bid: null,
          ultimo_arq_ok: false, ultimo_motivo: "formato", fallos_arq_consecutivos: 2,
        },
      },
    }));

    expect(node.querySelector("#tasaMexicoArq")?.textContent).toContain("falló");
    expect(node.querySelector("#tasaMexicoArq")?.textContent).toContain("formato");
    await act(async () => root.unmount());
  });

  it("does not warn when the last ARQ attempt was fine", async () => {
    const { node, root } = await renderPage(createFetchMock({
      ratesGet: {
        rates: FULL_RATES,
        arqRate: {
          valor: 18.647481, fuente: "arq", edad_min: 2, ask: "18.6697421235",
          ultimo_arq_ok: true, ultimo_motivo: "ok", fallos_arq_consecutivos: 0,
        },
      },
    }));

    expect(node.querySelector("#tasaMexicoArq")?.textContent).not.toContain("falló");
    await act(async () => root.unmount());
  });
});

// S2c: "Registros de la semana", the one table for the bot's lines and the typed ones, with the quick-entry bar, search,
// status chips, a service filter and the totals of what the filters leave.
describe("Registros de la semana (one table)", () => {
  const BOT = { ...DEL_COMPLETED, source: "completed_operation", entryDate: "2026-10-27" };
  const MANUAL = {
    id: "man-iza", operationId: null, source: "manual", status: "completed", service: "DIRECTO", customerName: "Iza", amount: 4000,
    amountCurrency: "GYD", entryDate: "2026-10-28", facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000, missingRates: [],
  };
  const SIN_TASA = { ...DEL_PENDING, source: "completed_operation", entryDate: "2026-10-28" };
  const COMBO = {
    id: "entry-combo", operationId: "op-combo", source: "completed_operation", status: "verified_pending", service: "COMBO", customerName: "Carla",
    amount: 1, amountCurrency: "COMBO", entryDate: "2026-10-28", facturadoGyd: 90000, invertidoGyd: null, retornoGyd: null, missingRates: ["combo_cost"],
  };
  const ALL = [BOT, MANUAL, SIN_TASA, COMBO];

  function fixture(entries: unknown[] = ALL, extra: Parameters<typeof createFetchMock>[0] = {}) {
    return createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", cutAt: "2026-10-26T12:00:00Z", chatOperations: { entries } },
      ratesGet: { rates: FULL_RATES },
      ...extra,
    });
  }
  const table = (node: HTMLElement) => node.querySelector('[data-testid="registros-tabla"]') as HTMLElement;
  const rows = (node: HTMLElement) => [...table(node).querySelectorAll("tbody tr[data-entry]")] as HTMLElement[];
  const names = (node: HTMLElement) => rows(node).map((r) => r.querySelector('td[data-label="Cliente"]')!.textContent);
  const chip = (node: HTMLElement, id: string) => node.querySelector(`[data-chip="${id}"]`) as HTMLButtonElement;
  const click = (el: Element) => act(() => (el as HTMLElement).click());

  it("holds the bot's lines and the typed ones in one table, the typed ones marked 'a mano'", async () => {
    const { node, root } = await renderPage(createFetchMock({
      calculadoraGet: { rawText: "", periodo: "", chatOperations: { entries: [BOT, MANUAL] } }, ratesGet: { rates: FULL_RATES },
    }));
    expect(node.querySelectorAll('[data-testid="registros-tabla"]')).toHaveLength(1);
    expect(names(node)).toEqual(["Raúl", "Izaa mano"]);
    expect(node.textContent).toContain("Registros de la semana");
    for (const gone of ["Desglose Semanal por Servicios", "Registros de la Semana", "Cierre Semanal PRO", "Tarifas Globales"]) expect(node.textContent).not.toContain(gone);
    const headers = [...table(node).querySelectorAll("thead th")].map((th) => th.textContent);
    expect(headers).toEqual(["Día", "Cliente", "Servicio", "Monto", "Tasa", "Facturado", "Invertido", "Ganancia", "Estado", "Acciones"]);
    await act(async () => root.unmount());
  });

  it("shows no 'Abrir chat' anywhere", async () => {
    const { node, root } = await renderPage(fixture());
    expect(node.textContent).not.toContain("Abrir chat");
    await act(async () => root.unmount());
  });

  it("counts the status chips and filters the table when one is pressed", async () => {
    const { node, root } = await renderPage(fixture());
    expect(["all", "completed", "pending", "sinTasa", "manual"].map((id) => chip(node, id).textContent)).toEqual([
      "Todas 4", "Completadas 2", "Pendientes 1", "Sin tasa 1", "A mano 1",
    ]);
    expect(chip(node, "all").getAttribute("aria-pressed")).toBe("true");
    click(chip(node, "sinTasa"));
    expect(names(node)).toEqual(["Bladimir"]);
    expect(chip(node, "sinTasa").getAttribute("aria-pressed")).toBe("true");
    click(chip(node, "manual"));
    expect(names(node)).toEqual(["Izaa mano"]);
    click(chip(node, "pending"));
    expect(names(node)).toEqual(["Carla"]);
    click(chip(node, "all"));
    expect(names(node)).toHaveLength(4);
    await act(async () => root.unmount());
  });

  it("searches by client or operation id and filters by service", async () => {
    const { node, root } = await renderPage(fixture());
    const search = node.querySelector('input[type="search"]') as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    act(() => { setter.call(search, "raú"); search.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(names(node)).toEqual(["Raúl"]);
    expect(chip(node, "all").textContent).toBe("Todas 1");
    act(() => { setter.call(search, ""); search.dispatchEvent(new Event("input", { bubbles: true })); });
    const select = node.querySelector('select[aria-label="Servicio"]') as HTMLSelectElement;
    const selSetter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
    act(() => { selSetter.call(select, "CUP"); select.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(names(node)).toEqual(["Bladimir"]);
    await act(async () => root.unmount());
  });

  it("filters the table when a service or a client of the overview is pressed, and releases it when pressed again", async () => {
    const { node, root } = await renderPage(fixture());
    const serviceButtons = [...node.querySelectorAll('[data-testid="semana-servicios"] button')] as HTMLButtonElement[];
    const zelle = serviceButtons.find((b) => b.textContent!.includes("Zelle"))!;
    click(zelle);
    expect(names(node)).toEqual(["Raúl"]);
    expect(zelle.getAttribute("aria-pressed")).toBe("true");
    click(zelle);
    expect(names(node)).toHaveLength(4);
    const iza = [...node.querySelectorAll('[data-testid="semana-clientes"] button')].find((b) => b.textContent!.includes("Iza"))!;
    click(iza);
    expect(names(node)).toEqual(["Izaa mano"]);
    expect(node.textContent).toContain("Cliente: Iza");
    click(node.querySelector('button[aria-label="Quitar el filtro de cliente"]')!);
    expect(names(node)).toHaveLength(4);
    await act(async () => root.unmount());
  });

  it("totals only the completed lines the filters leave", async () => {
    const { node, root } = await renderPage(fixture());
    const totals = () => node.querySelector('[data-testid="registros-totales"]')!.textContent;
    expect(totals()).toContain("30,000");
    expect(totals()).toContain("24,000");
    expect(totals()).toContain("6,000");
    click(chip(node, "manual"));
    expect(totals()).toContain("4,000");
    expect(totals()).not.toContain("6,000");
    await act(async () => root.unmount());
  });

  it("says so when the filters leave nothing, and lets the user clear them", async () => {
    const { node, root } = await renderPage(fixture());
    click(chip(node, "manual"));
    click(chip(node, "sinTasa"));
    expect(names(node)).toEqual(["Bladimir"]);
    const search = node.querySelector('input[type="search"]') as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    act(() => { setter.call(search, "zzz"); search.dispatchEvent(new Event("input", { bubbles: true })); });
    expect(node.textContent).toContain("Ninguna línea coincide con los filtros");
    click([...node.querySelectorAll("button")].find((b) => b.textContent === "Quitar los filtros")!);
    expect(names(node)).toHaveLength(4);
    await act(async () => root.unmount());
  });

  it("marks a line waiting for a rate with 'Poner tasa', which opens that rate in Tasas actuales; a COMBO waiting for its cost has none", async () => {
    const withKey = { ...SIN_TASA, missingRates: ["usdt_sell_cup"] };
    const { node, root } = await renderPage(fixture([withKey, COMBO]));
    const [cup, combo] = rows(node);
    expect(cup!.querySelector('td[data-label="Estado"]')!.textContent).toContain("Sin tasa");
    const poner = [...cup!.querySelectorAll("button")].find((b) => b.textContent === "Poner tasa")!;
    expect([...combo!.querySelectorAll("button")].some((b) => b.textContent === "Poner tasa")).toBe(false);
    expect(combo!.querySelector('td[data-label="Estado"]')!.textContent).toContain("Pendiente");
    click(poner);
    expect(node.querySelector('[data-rate="usdt_sell_cup"] input')).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("jumps to the lines waiting for a rate from the Hoy notice", async () => {
    const { node, root } = await renderPage(fixture());
    const hoy = node.querySelector('[data-testid="semana-hoy"]')!;
    expect(hoy.textContent).toContain("1 sin tasa");
    expect(hoy.textContent).toContain("1 pendiente");
    click([...hoy.querySelectorAll("button")].find((b) => b.getAttribute("data-show") === "sinTasa")!);
    expect(names(node)).toEqual(["Bladimir"]);
    await act(async () => root.unmount());
  });

  it("previews the typed line in the table's own columns before it is saved", async () => {
    const { node, root } = await renderPage(fixture([BOT]));
    const box = node.querySelector("#rawText") as HTMLTextAreaElement;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!;
    await act(async () => { setter.call(box, "Fran 50k CUP (235/980)"); box.dispatchEvent(new Event("input", { bubbles: true })); });
    const preview = table(node).querySelector("tr[data-preview]") as HTMLElement;
    expect(preview).not.toBeNull();
    expect(preview.textContent).toContain("Fran");
    expect(preview.textContent).toContain("Vista previa");
    expect(preview.textContent).toContain("al guardar");
    expect(preview.textContent).toContain("a mano");
    expect(table(node).querySelectorAll("tr[data-preview]")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it("offers the format hints and opens the full guide from 'Todos los formatos'", async () => {
    const { node, root } = await renderPage(fixture([BOT]));
    expect(node.textContent).toContain("Pedro 150 MLC (30%/240/245)");
    const guide = node.querySelector("#guiaFormatos") as HTMLDetailsElement;
    expect(guide.open).toBe(false);
    click([...node.querySelectorAll("button")].find((b) => b.textContent === "Todos los formatos")!);
    expect(guide.open).toBe(true);
    expect(guide.textContent).toContain("Recargas Promo");
    await act(async () => root.unmount());
  });
});
