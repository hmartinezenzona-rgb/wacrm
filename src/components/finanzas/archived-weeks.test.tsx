// @vitest-environment jsdom
// The archived weeks ("Semanas anteriores") of the weekly cut, read-only, now in the Cierres tab. They come from the
// same endpoints the Calculadora used (GET /api/calculadora/weeks and /weeks/{id}).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ArchivedWeeks } from "./archived-weeks";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

function flush() {
  return act(async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); });
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}

function createFetchMock(config: {
  weeksGet?: { weeks: unknown[] };
  weekGet?: (weekId: string) => { status: number; body?: unknown };
}) {
  return vi.fn((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url === "/api/calculadora/weeks") return Promise.resolve(jsonResponse(config.weeksGet ?? { weeks: [] }));
    const weekMatch = /^\/api\/calculadora\/weeks\/([^/]+)$/.exec(url);
    if (weekMatch) {
      const result = config.weekGet ? config.weekGet(weekMatch[1]!) : { status: 404, body: { error: "Not found" } };
      return Promise.resolve(jsonResponse(result.body ?? {}, result.status));
    }
    return Promise.reject(new Error(`Unhandled fetch ${url}`));
  });
}

async function renderWeeks(fetchMock: ReturnType<typeof createFetchMock>) {
  vi.stubGlobal("fetch", fetchMock);
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ArchivedWeeks />));
  await flush();
  return { node, root };
}

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

const DEL_COMPLETED = {
  id: "entry-a", operationId: "op-a", status: "completed", service: "ZELLE", customerName: "Raúl", amount: 100,
  amountCurrency: "USD", entryDate: "2026-09-12", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, missingRates: [],
};
const MANUAL_ROW = {
  id: "man-iza", operationId: null, source: "manual", status: "completed", service: "DIRECTO", customerName: "Iza", amount: 4000,
  amountCurrency: "GYD", entryDate: "2026-10-06", facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000, missingRates: [],
};

const toneOf = (row: Element, label: string) => row.querySelector(`td[data-label="${label}"]`)?.getAttribute("data-tone") ?? null;
const tones = (root: ParentNode) => [...root.querySelectorAll(".legacyTotalBox p [data-tone]")].map((el) => (el as HTMLElement).dataset.tone);

describe("archived weeks (Cierres tab)", () => {
  const SUMMARY = {
    id: "week-1", cutAt: "2026-10-03T12:00:00+00:00", periodo: "SEMANA 1",
    manualTotals: { facturadoGyd: 1000, invertidoGyd: 800, retornoGyd: 200 },
    chatTotals: { count: 1, facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 },
  };
  const FULL_WEEK = {
    ...SUMMARY,
    rawText: "• Fran 50k CUP (235/980)",
    entries: [{ ...DEL_COMPLETED, id: "arch-1", customerName: "Archivada Ana" }],
  };
  function fixture(overrides: Parameters<typeof createFetchMock>[0] = {}) {
    return createFetchMock({
      weeksGet: { weeks: [SUMMARY] },
      weekGet: (id) => (id === "week-1" ? { status: 200, body: { week: FULL_WEEK } } : { status: 404, body: {} }),
      ...overrides,
    });
  }

  // Owner, 2026-10-07: the history opens on demand. In the Cierres tab it is the main content, so it starts open.
  it("is a details section, open, with the number of weeks in its summary, and holds the open week", async () => {
    const { node, root } = await renderWeeks(fixture());

    const section = node.querySelector("#semanasAnteriores") as HTMLDetailsElement;
    expect(section.tagName).toBe("DETAILS");
    expect(section.open).toBe(true);
    const summary = section.querySelector("summary") as HTMLElement;
    expect(summary.textContent).toContain("Semanas anteriores");
    expect(summary.textContent).toMatch(/\(\d+\)/);
    expect(Array.from(node.querySelectorAll("h2")).some((h) => (h.textContent ?? "").includes("Semanas anteriores"))).toBe(false);

    await act(async () => { (node.querySelector("#verSemana-week-1") as HTMLButtonElement).click(); });
    await act(async () => { await Promise.resolve(); });
    expect(section.querySelector("#semanaArchivada")).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("styles itself with the legacy calculator classes, without the full-page shell", async () => {
    const { node, root } = await renderWeeks(fixture());
    const shell = node.querySelector(".legacyCalc") as HTMLElement;
    expect(shell).not.toBeNull();
    expect(shell.classList.contains("legacyEmbedded")).toBe(true);
    await act(async () => root.unmount());
  });

  it("lists the archived weeks compactly: cut date, period and totals", async () => {
    const { node, root } = await renderWeeks(fixture());

    const card = node.querySelector("#semanasAnteriores") as HTMLElement;
    expect(card).not.toBeNull();
    expect(card.textContent).toContain("Semanas anteriores");
    expect(card.textContent).toContain("SEMANA 1");
    expect(card.textContent).toContain("2026-10-03");
    // manual + chat: 1000 + 26000, 800 + 24000, 200 + 2000
    expect(card.textContent).toContain("27 000,00");
    expect(card.textContent).toContain("24 800,00");
    expect(card.textContent).toContain("2 200,00");
    await act(async () => root.unmount());
  });

  it("says so when there are no archived weeks", async () => {
    const { node, root } = await renderWeeks(fixture({ weeksGet: { weeks: [] } }));
    expect(node.querySelector("#semanasAnteriores")?.textContent).toContain("Aún no hay semanas archivadas.");
    await act(async () => root.unmount());
  });

  it("reads the list again every time it opens, so a cut made in the Semana tab shows up", async () => {
    const weeks = [SUMMARY];
    const fetchMock = createFetchMock({ weeksGet: { weeks } });
    const first = await renderWeeks(fetchMock);
    expect(first.node.querySelector("#verSemana-week-2")).toBeNull();
    await act(async () => first.root.unmount());
    document.body.replaceChildren();

    weeks.unshift({ ...SUMMARY, id: "week-2", periodo: "SEMANA 2" });
    const second = await renderWeeks(fetchMock);
    expect(second.node.querySelector("#verSemana-week-2")).not.toBeNull();
    expect(second.node.querySelector("#verSemana-week-1")).not.toBeNull();
    expect(fetchMock.mock.calls.filter(([url]) => url === "/api/calculadora/weeks")).toHaveLength(2);
    await act(async () => second.root.unmount());
  });

  it("opens an archived week read-only: text, period, totals and the entries of that week, with no edit or delete", async () => {
    const { node, root } = await renderWeeks(fixture());

    await act(async () => { (node.querySelector("#verSemana-week-1") as HTMLButtonElement).click(); });
    await flush();

    const view = node.querySelector("#semanaArchivada") as HTMLElement;
    expect(view).not.toBeNull();
    expect(view.textContent).toContain("SEMANA 1");
    expect(view.querySelector("pre")?.textContent).toBe("• Fran 50k CUP (235/980)");
    expect(view.textContent).toContain("Operaciones");
    expect(view.textContent).toContain("Archivada Ana");
    expect(view.textContent).toContain("26 000,00");
    expect(view.querySelector("textarea, input")).toBeNull();
    expect(view.querySelector("[id^=eliminarEntry], [id^=editarEntry]")).toBeNull();

    await act(async () => { (node.querySelector("#cerrarSemana") as HTMLButtonElement).click(); });
    expect(node.querySelector("#semanaArchivada")).toBeNull();
    await act(async () => root.unmount());
  });

  it("a week that cannot be read shows an error and no view", async () => {
    const { node, root } = await renderWeeks(fixture({ weekGet: () => ({ status: 500, body: {} }) }));

    await act(async () => { (node.querySelector("#verSemana-week-1") as HTMLButtonElement).click(); });
    await flush();

    expect(node.querySelector("#semanaArchivada")).toBeNull();
    expect(node.querySelector("#semanasAnteriores")?.textContent).toContain("No se pudo abrir la semana.");
    await act(async () => root.unmount());
  });

  it("a list that cannot be read stays empty without breaking the tab", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(jsonResponse({}, 500))));
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<ArchivedWeeks />));
    await flush();
    expect(node.querySelector("#semanasAnteriores")?.textContent).toContain("Aún no hay semanas archivadas.");
    await act(async () => root.unmount());
  });

  it("an archived week shows its manual operations with the mark, read only, next to the bot's; the totals are the week's", async () => {
    const week = {
      id: "week-9", cutAt: "2026-10-08T12:00:00+00:00", periodo: "SEMANA 9",
      manualTotals: { facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000 },
      chatTotals: { count: 1, facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 },
      rawText: "",
      entries: [DEL_COMPLETED, { ...MANUAL_ROW, id: "arch-man" }],
    };
    const { node, root } = await renderWeeks(fixture({
      weeksGet: { weeks: [{ ...week, entries: undefined, rawText: undefined }] },
      weekGet: () => ({ status: 200, body: { week } }),
    }));

    await act(async () => { (node.querySelector("#verSemana-week-9") as HTMLButtonElement).click(); });
    await flush();

    const view = node.querySelector("#semanaArchivada") as HTMLElement;
    const rows = [...view.querySelectorAll("tbody tr")] as HTMLElement[];
    expect(rows).toHaveLength(2);
    expect(rows[1]!.querySelector('td[data-label="Tipo"]')!.textContent).toContain("Manual");
    expect(rows[0]!.querySelector('td[data-label="Tipo"]')!.textContent).not.toContain("Manual");
    expect(view.textContent).toContain("30 000,00");
    expect(view.querySelector("[id^=eliminarEntry], [id^=editarEntry]")).toBeNull();
    await act(async () => root.unmount());
  });

  it("tones the Fact. / Inv. / Ganancia of the list, and shows a loss week in the loss tone", async () => {
    const { node, root } = await renderWeeks(fixture());
    const row = node.querySelector("#semanasAnteriores tbody tr")!;
    expect([toneOf(row, "Fact. (GYD)"), toneOf(row, "Inv. (GYD)"), toneOf(row, "Ganancia")]).toEqual(["in", "out", "profit"]);
    for (const label of ["Corte", "Período"]) expect(toneOf(row, label)).toBeNull();
    await act(async () => root.unmount());

    const lossWeek = { ...SUMMARY, manualTotals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 }, chatTotals: { count: 1, facturadoGyd: 100, invertidoGyd: 300, retornoGyd: -200 } };
    const loss = await renderWeeks(createFetchMock({ weeksGet: { weeks: [lossWeek] } }));
    expect(toneOf(loss.node.querySelector("#semanasAnteriores tbody tr")!, "Ganancia")).toBe("loss");
    await act(async () => loss.root.unmount());
  });

  it("applies the money tones and the service dot inside the week view", async () => {
    const { node, root } = await renderWeeks(fixture({
      weekGet: () => ({ status: 200, body: { week: { ...FULL_WEEK, manualTotals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 } } } }),
    }));
    await act(async () => { (node.querySelector("#verSemana-week-1") as HTMLButtonElement).click(); });
    await flush();

    const view = node.querySelector("#semanaArchivada") as HTMLElement;
    expect(tones(view)).toEqual(["in", "out", "profit"]);
    expect(view.querySelectorAll(".legacyTotalBox p")[2]!.textContent).toBe("+2\u202f000,00");
    const row = view.querySelector("tbody tr")!;
    expect([toneOf(row, "Fact. (GYD)"), toneOf(row, "Inv. (GYD)"), toneOf(row, "Ganancia")]).toEqual(["in", "out", "profit"]);
    expect(toneOf(row, "Monto")).toBeNull();
    expect(view.querySelector('tbody td[data-label="Tipo"] [data-service]')?.getAttribute("data-service")).toBe("zelle");
    await act(async () => root.unmount());
  });

  it("shows no emoji, with the list and an open week", async () => {
    const { node, root } = await renderWeeks(fixture());
    await act(async () => { (node.querySelector("#verSemana-week-1") as HTMLButtonElement).click(); });
    await flush();
    expect(node.querySelector("#semanaArchivada")).not.toBeNull();
    expect(node.textContent).not.toMatch(/\p{Extended_Pictographic}/u);
    await act(async () => root.unmount());
  });
});
