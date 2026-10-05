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

const RATE_OPTIONS = [
  ["cup_global_rate", "Tarifa CUP global"],
  ["usdt_buy_gyd", "Compra USDT (GYD)"],
  ["usdt_sell_gyd", "Venta USDT (GYD)"],
  ["usdt_sell_cup", "Venta USDT (CUP)"],
  ["zelle_sell_gyd", "Zelle desde 50 USD"],
  ["zelle_sell_gyd_1000", "Zelle desde 1,000 USD"],
  ["zelle_sell_gyd_2000", "Zelle desde 2,000 USD"],
  ["efectivo_usd_gyd", "Efectivo USD (GYD por dólar)"],
  ["recarga_costo_usdt", "Recarga: costo (USDT)"],
] as const;

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
  effectiveAt: "2026-09-10T00:00:00Z",
  setBy: null,
};

function selectRate(node: HTMLElement, key: string) {
  const select = node.querySelector("#tasaSeleccionada") as HTMLSelectElement;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, key);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function listRows(node: HTMLElement) {
  return [...node.querySelectorAll("#tasasActuales .legacyRateRow")].map((row) => [
    row.querySelector("dt")?.textContent,
    row.querySelector("dd")?.textContent,
  ]);
}

function updateButton(node: HTMLElement) {
  return node.querySelector("#actualizarTasa") as HTMLButtonElement;
}

describe("calculator single-rate editor (Tarifas Globales)", () => {
  it("the dropdown lists the nine rates in order with their Spanish labels", async () => {
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES } }));

    const options = [...node.querySelectorAll("#tasaSeleccionada option")].map((o) => [
      (o as HTMLOptionElement).value,
      o.textContent,
    ]);
    expect(options).toEqual(RATE_OPTIONS.map(([key, label]) => [key, label]));
    await act(async () => root.unmount());
  });

  it("labels the dropdown and the value field", async () => {
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES } }));

    expect(node.querySelector('label[for="tasaSeleccionada"]')?.textContent).toBe("Tasa a cambiar");
    expect(node.querySelector('label[for="tasaValor"]')?.textContent).toBe("Nuevo valor");
    expect((node.querySelector("#tasaValor") as HTMLInputElement).type).toBe("number");
    await act(async () => root.unmount());
  });

  it("lists every current rate read-only, with a dash for the ones not set", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: { ...FULL_RATES, usdtSellCup: null, efectivoUsdGyd: null } } }),
    );

    expect(listRows(node)).toEqual([
      ["Tarifa CUP global", "3"],
      ["Compra USDT (GYD)", "240"],
      ["Venta USDT (GYD)", "260"],
      ["Venta USDT (CUP)", "—"],
      ["Zelle desde 50 USD", "260"],
      ["Zelle desde 1,000 USD", "250"],
      ["Zelle desde 2,000 USD", "245"],
      ["Efectivo USD (GYD por dólar)", "—"],
      ["Recarga: costo (USDT)", "4.5"],
    ]);
    expect(node.querySelectorAll("#tasasActuales input").length).toBe(0);
    await act(async () => root.unmount());
  });

  it("no rates set yet -> every value is a dash and the field is empty, never a fake default", async () => {
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: null } }));

    expect(listRows(node).map(([, value]) => value)).toEqual(Array(9).fill("—"));
    expect(inputValue(node, "tasaValor")).toBe("");
    await act(async () => root.unmount());
  });

  it("selecting a rate fills the value field with its current value (empty when unset)", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: { ...FULL_RATES, usdtSellCup: null } } }),
    );

    expect(inputValue(node, "tasaValor")).toBe("3");
    act(() => selectRate(node, "zelle_sell_gyd_1000"));
    expect(inputValue(node, "tasaValor")).toBe("250");
    act(() => selectRate(node, "usdt_sell_cup"));
    expect(inputValue(node, "tasaValor")).toBe("");
    await act(async () => root.unmount());
  });

  it("Actualizar posts only the selected rate with the loaded version id and refreshes the list", async () => {
    let capturedBody: { rates: Record<string, unknown>; expectedVersionId?: string } | undefined;
    const ratesPost = vi.fn((body: { rates: Record<string, unknown>; expectedVersionId?: string }): RatesPostResult => {
      capturedBody = body;
      return { status: 200, body: { rates: { ...FULL_RATES, id: "rate-2", zelleSellGyd1000: 255 } } };
    });
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

    act(() => selectRate(node, "zelle_sell_gyd_1000"));
    act(() => setInputValue(node, "tasaValor", "255"));
    await act(async () => { updateButton(node).click(); });
    await flush();

    expect(ratesPost).toHaveBeenCalledTimes(1);
    expect(capturedBody).toEqual({ rates: { zelle_sell_gyd_1000: 255 }, expectedVersionId: "rate-1" });
    expect(listRows(node)[5]).toEqual(["Zelle desde 1,000 USD", "255"]);
    expect(inputValue(node, "tasaValor")).toBe("255");
    expect(node.querySelector("#tasasMensaje")?.textContent).toContain("Tasa actualizada");
    await act(async () => root.unmount());
  });

  it("the next update uses the new version id from the response", async () => {
    const bodies: Array<{ rates: Record<string, unknown>; expectedVersionId?: string }> = [];
    const ratesPost = vi.fn((body: { rates: Record<string, unknown>; expectedVersionId?: string }): RatesPostResult => {
      bodies.push(body);
      return { status: 200, body: { rates: { ...FULL_RATES, id: `rate-${bodies.length + 1}`, cupGlobalRate: 4 } } };
    });
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

    act(() => setInputValue(node, "tasaValor", "4"));
    await act(async () => { updateButton(node).click(); });
    await flush();
    act(() => setInputValue(node, "tasaValor", "5"));
    await act(async () => { updateButton(node).click(); });
    await flush();

    expect(bodies.map((b) => b.expectedVersionId)).toEqual(["rate-1", "rate-2"]);
    await act(async () => root.unmount());
  });

  it("with no version yet the post carries no expectedVersionId", async () => {
    const ratesPost = vi.fn((): RatesPostResult => ({ status: 200, body: { rates: { ...FULL_RATES, id: "rate-1", cupGlobalRate: 3 } } }));
    const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: null }, ratesPost }));

    act(() => setInputValue(node, "tasaValor", "3"));
    await act(async () => { updateButton(node).click(); });
    await flush();

    expect(ratesPost).toHaveBeenCalledWith({ rates: { cup_global_rate: 3 } });
    await act(async () => root.unmount());
  });

  it.each([["empty", ""], ["zero", "0"], ["negative", "-5"]])(
    "an invalid value (%s) is not sent and shows a message",
    async (_name, value) => {
      const ratesPost = vi.fn((): RatesPostResult => ({ status: 200, body: { rates: FULL_RATES } }));
      const { node, root } = await renderPage(createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost }));

      act(() => setInputValue(node, "tasaValor", value));
      await act(async () => { updateButton(node).click(); });
      await flush();

      expect(ratesPost).not.toHaveBeenCalled();
      expect(node.querySelector("#tasasMensaje")?.textContent).toContain("número mayor que 0");
      await act(async () => root.unmount());
    },
  );

  it("403 shows the admin-only message and disables the dropdown, the field and the button", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost: () => ({ status: 403, body: { error: "Forbidden" } }) }),
    );

    act(() => setInputValue(node, "tasaValor", "4"));
    await act(async () => { updateButton(node).click(); });
    await flush();

    expect(node.textContent).toContain("Solo un administrador puede modificar las tasas.");
    expect((node.querySelector("#tasaSeleccionada") as HTMLSelectElement).disabled).toBe(true);
    expect(isInputDisabled(node, "tasaValor")).toBe(true);
    expect(updateButton(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("409 tells the user to reload, without disabling anything", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost: () => ({ status: 409, body: { error: "stale" } }) }),
    );

    act(() => setInputValue(node, "tasaValor", "4"));
    await act(async () => { updateButton(node).click(); });
    await flush();

    expect(node.textContent).toContain("Las tasas se modificaron en otro lugar; recarga la página.");
    expect(isInputDisabled(node, "tasaValor")).toBe(false);
    expect(updateButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("other failures show a generic save-failed message and keep the list", async () => {
    const { node, root } = await renderPage(
      createFetchMock({ ratesGet: { rates: FULL_RATES }, ratesPost: () => ({ status: 500, body: { error: "boom" } }) }),
    );

    act(() => setInputValue(node, "tasaValor", "4"));
    await act(async () => { updateButton(node).click(); });
    await flush();

    expect(node.textContent).toContain("No se pudieron guardar las tasas.");
    expect(listRows(node)[0]).toEqual(["Tarifa CUP global", "3"]);
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

    const banner = node.querySelector("#pendingBanner")!;
    expect(banner.textContent).toContain("Marta");
    expect(banner.textContent).toContain("Falta el costo del combo: anótalo en el panel de la conversación");
    expect(banner.textContent).not.toContain("comboCosto");
    expect(banner.textContent).not.toContain("tasas");
    const row = node.querySelector('td[data-label="Estado"]')!;
    expect(row.textContent).toContain("Falta el costo del combo: anótalo en el panel de la conversación");
    expect(row.textContent).not.toContain("comboCosto");
    // No rates-resolution action on a COMBO line: the Acciones cell stays empty.
    expect(node.querySelector('td[data-label="Acciones"]')!.querySelector("button")).toBeNull();
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

    expect(node.querySelector("#pendingBanner")).toBeNull();
    const cells = Array.from(node.querySelectorAll("#cardRegistros ~ * td, .legacyParsedTable td")).map((c) => c.textContent);
    expect(cells).toContain("Completada");
    expect(node.textContent).toContain("55000.00");
    expect(node.textContent).toContain("41000.00");
    expect(node.textContent).toContain("14000.00");
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

    const banner = node.querySelector("#pendingBanner")!;
    expect(banner.textContent).toContain("Falta el costo del combo");
    expect(banner.textContent).toContain("Bladimir (CUP): usdtSellCup");
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

  it("sizes the Acciones column to its content instead of sharing the table width", async () => {
    const fetchMock = fixture();
    const { node, root } = await renderPage(fetchMock);

    const header = Array.from(node.querySelectorAll("th")).find((th) => th.textContent === "Acciones");
    const cell = node.querySelector("#editarEntry-entry-a")?.closest("td");
    expect(header?.classList.contains("legacyActionsCell")).toBe(true);
    expect(cell?.classList.contains("legacyActionsCell")).toBe(true);
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
