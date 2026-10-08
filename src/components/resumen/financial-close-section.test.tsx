// @vitest-environment jsdom
// Spec: financial close on /resumen (odd/tasks/financial-close-resumen.md, T3).
// Covers the section's behavior: it opens on the current Guyana week, the
// period buttons and previous/next ask the loader for the right range, a
// custom range is validated before any call, the totals/breakdowns/detail
// render from the loaded close, voided and pending entries sit in their own
// section, and a failed load shows a retry instead of crashing.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import type { FinancialClose } from "@/lib/financial-close/read-model";

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

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }));

// Tremor's chart needs ResizeObserver/SVG layout jsdom doesn't have; the
// chart itself is vendored and not under test here.
vi.mock("@/components/tremor/bar-chart", () => ({
  BarChart: (props: { data: unknown[] }) => <div data-testid="bar-chart" data-points={props.data.length} />,
}));

const loadFinancialClose = vi.fn();
vi.mock("@/lib/financial-close/load", () => ({
  loadFinancialClose: (...args: unknown[]) => loadFinancialClose(...args),
}));

const T = en.Resumen.cierre;

function close(overrides: Partial<FinancialClose> = {}): FinancialClose {
  return {
    range: { desde: "2026-09-21", hasta: "2026-09-27" },
    timeZone: "America/Guyana",
    totals: { operations: 2, facturadoGyd: 3000, invertidoGyd: 2200, retornoGyd: 800 },
    byService: [
      { service: "ZELLE", operations: 1, facturadoGyd: 2000, invertidoGyd: 1500, retornoGyd: 500 },
      { service: "CUP", operations: 1, facturadoGyd: 1000, invertidoGyd: 700, retornoGyd: 300 },
    ],
    byDay: [
      { day: "2026-09-21", operations: 0, facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 },
      { day: "2026-09-22", operations: 2, facturadoGyd: 3000, invertidoGyd: 2200, retornoGyd: 800 },
    ],
    detail: [
      {
        id: "e1",
        source: "completed_operation",
        operationId: "11111111-aaaa-bbbb-cccc-000000000001",
        day: "2026-09-22",
        completedAt: "2026-09-22T15:05:00Z",
        customerName: "Ana Pérez",
        service: "CUP",
        amount: 3000,
        amountCurrency: "CUP",
        cupRate: 975,
        cupGlobalRate: 3,
        usdtBuyGyd: null,
        usdtSellGyd: null,
        rateVersionId: "rv1",
        facturadoGyd: 1000,
        invertidoGyd: 700,
        retornoGyd: 300,
        deliveryMode: "proof_sent",
        actorUserId: "u1",
        actorName: "Humberto",
      },
    ],
    excluded: [
      {
        id: "e3",
        source: "completed_operation",
        operationId: "11111111-aaaa-bbbb-cccc-000000000003",
        day: "2026-09-22",
        completedAt: "2026-09-22T16:00:00Z",
        customerName: "Luis",
        service: "CUP",
        amount: 999,
        amountCurrency: "CUP",
        cupRate: null,
        cupGlobalRate: null,
        usdtBuyGyd: null,
        usdtSellGyd: null,
        rateVersionId: null,
        facturadoGyd: 999,
        invertidoGyd: 600,
        retornoGyd: 399,
        deliveryMode: null,
        actorUserId: null,
        actorName: null,
        status: "void",
        voidReason: "cliente cancelo",
        voidedAt: "2026-09-22T17:00:00Z",
        missingInputs: [],
      },
    ],
    ...overrides,
  };
}

async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

async function render() {
  const { FinancialCloseSection } = await import("./financial-close-section");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<FinancialCloseSection />));
  await flush();
  return { node, root };
}

function button(node: Element, text: string) {
  const found = Array.from(node.querySelectorAll("button")).find(
    (b) => b.textContent?.trim() === text || b.getAttribute("aria-label") === text,
  );
  if (!found) throw new Error(`no button "${text}"`);
  return found;
}

async function click(el: Element) {
  await act(async () => {
    el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  });
  await flush();
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function lastRange() {
  return loadFinancialClose.mock.calls.at(-1)?.[1];
}

describe("FinancialCloseSection", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    // Thursday 2026-09-24 14:00 in Guyana (18:00 UTC).
    vi.setSystemTime(new Date("2026-09-24T18:00:00Z"));
    loadFinancialClose.mockReset();
    loadFinancialClose.mockResolvedValue({ ok: true, data: close() });
  });

  afterEach(() => {
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  it("opens on the current Guyana week and renders totals, breakdowns and detail", async () => {
    const { node, root } = await render();

    expect(lastRange()).toEqual({ desde: "2026-09-21", hasta: "2026-09-27" });
    const text = node.textContent ?? "";
    expect(text).toContain(T.title);
    expect(text).toContain("3\u202f000 GYD");
    expect(text).toContain("2\u202f200 GYD");
    expect(text).toContain("800 GYD");
    expect(text).toContain(T.totales.margen.replace("{pct}", "26.7"));
    // By service, in the order the RPC ranked them.
    const services = Array.from(node.querySelectorAll("[data-testid='service-row']")).map((r) => r.getAttribute("data-service"));
    expect(services).toEqual(["ZELLE", "CUP"]);
    expect(node.querySelector("[data-testid='bar-chart']")?.getAttribute("data-points")).toBe("2");
    // Detail row with Guyana time (15:05 UTC = 11:05 GY), delivery and actor.
    const detail = node.querySelector("[data-testid='detail-row']")!;
    expect(detail.textContent).toContain("Ana Pérez");
    expect(detail.textContent).toContain("11:05");
    expect(detail.textContent).toContain(T.entrega.proof_sent);
    expect(detail.textContent).toContain("Humberto");
    // Voided entry in its own section, with the reason.
    const excluded = node.querySelector("[data-testid='excluded-row']")!;
    expect(excluded.textContent).toContain(T.estado.void);
    expect(excluded.textContent).toContain("cliente cancelo");
    await act(async () => root.unmount());
  });

  it("labels the lines typed in the Calculator as manual, next to the bot's operations", async () => {
    const base = close();
    const manual = {
      ...base.detail[0]!,
      id: "m1",
      source: "manual" as const,
      operationId: null,
      customerName: "Gerardo",
      service: "DIRECTO",
      amountCurrency: "GYD",
      deliveryMode: null,
      actorName: "Osmany",
    };
    loadFinancialClose.mockResolvedValue({ ok: true, data: { ...base, detail: [base.detail[0]!, manual] } });
    const { node, root } = await render();

    const rows = Array.from(node.querySelectorAll("[data-testid='detail-row']"));
    expect(rows).toHaveLength(2);
    expect(rows[0]!.textContent).not.toContain(T.manual);
    expect(rows[1]!.textContent).toContain("Gerardo");
    expect(rows[1]!.textContent).toContain(T.manual);
    expect(rows[1]!.textContent).toContain(en.ServiceNames.tramites);
    expect(rows[1]!.querySelector("[data-testid='manual-badge']")).not.toBeNull();
    expect(rows[0]!.querySelector("[data-testid='manual-badge']")).toBeNull();
    await act(async () => root.unmount());
  });

  it("switches period kind and moves backwards and forwards", async () => {
    const { node, root } = await render();

    await click(button(node, T.periodo.month));
    expect(lastRange()).toEqual({ desde: "2026-09-01", hasta: "2026-09-30" });

    await click(button(node, T.anterior));
    expect(lastRange()).toEqual({ desde: "2026-08-01", hasta: "2026-08-31" });

    await click(button(node, T.periodo.day));
    // Switching kind re-anchors on the period being viewed, not on today.
    expect(lastRange()).toEqual({ desde: "2026-08-01", hasta: "2026-08-01" });

    await click(button(node, T.siguiente));
    expect(lastRange()).toEqual({ desde: "2026-08-02", hasta: "2026-08-02" });

    await click(button(node, T.hoy));
    expect(lastRange()).toEqual({ desde: "2026-09-24", hasta: "2026-09-24" });
    await act(async () => root.unmount());
  });

  it("names the period in words and never moves past today", async () => {
    const { node, root } = await render();
    expect(node.textContent).toContain("Semana del 21 al 27 sep 2026");
    // The current week is still running: there is no next week to see.
    expect(button(node, T.siguiente).disabled).toBe(true);

    await click(button(node, T.anterior));
    expect(node.textContent).toContain("Semana del 14 al 20 sep 2026");
    expect(button(node, T.siguiente).disabled).toBe(false);
    await click(button(node, T.siguiente));
    expect(lastRange()).toEqual({ desde: "2026-09-21", hasta: "2026-09-27" });
    expect(button(node, T.siguiente).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("refuses a custom range that ends in the future", async () => {
    const { node, root } = await render();
    await click(button(node, T.periodo.range));
    const calls = loadFinancialClose.mock.calls.length;
    const [desde, hasta] = Array.from(node.querySelectorAll<HTMLInputElement>("input[type='date']"));
    await act(async () => {
      setValue(desde, "2026-09-20");
      setValue(hasta, "2026-09-25");
    });
    await click(button(node, T.aplicar));
    expect(node.textContent).toContain(T.rangoError.future);
    expect(loadFinancialClose.mock.calls.length).toBe(calls);
    await act(async () => root.unmount());
  });

  it("validates a custom range before asking for it", async () => {
    const { node, root } = await render();
    await click(button(node, T.periodo.range));
    const calls = loadFinancialClose.mock.calls.length;

    const [desde, hasta] = Array.from(node.querySelectorAll<HTMLInputElement>("input[type='date']"));
    await act(async () => {
      setValue(desde, "2026-09-10");
      setValue(hasta, "2026-09-01");
    });
    await click(button(node, T.aplicar));
    expect(node.textContent).toContain(T.rangoError.reversed);
    expect(loadFinancialClose.mock.calls.length).toBe(calls);

    await act(async () => setValue(hasta, "2026-09-15"));
    await click(button(node, T.aplicar));
    expect(lastRange()).toEqual({ desde: "2026-09-10", hasta: "2026-09-15" });
    await act(async () => root.unmount());
  });

  it("shows the empty message when nothing was completed in the period", async () => {
    loadFinancialClose.mockResolvedValue({
      ok: true,
      data: close({
        totals: { operations: 0, facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 },
        byService: [],
        detail: [],
        excluded: [],
      }),
    });
    const { node, root } = await render();
    expect(node.textContent).toContain(T.sinDatos);
    expect(node.querySelector("[data-testid='excluded-row']")).toBeNull();
    await act(async () => root.unmount());
  });

  it("exports the loaded period as a CSV named after the range", async () => {
    const createObjectURL = vi.fn(() => "blob:cierre");
    const revokeObjectURL = vi.fn();
    Object.assign(URL, { createObjectURL, revokeObjectURL });
    const clicked: string[] = [];
    const anchorClick = vi
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(function (this: HTMLAnchorElement) {
        clicked.push(this.download);
      });

    const { node, root } = await render();
    await click(button(node, T.exportar));

    expect(clicked).toEqual(["cierre-financiero_2026-09-21_2026-09-27.csv"]);
    const blob = (createObjectURL.mock.calls[0] as unknown as [Blob])[0];
    // jsdom's Blob has no .text(); FileReader is supported.
    const text = await new Promise<string>((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result));
      reader.readAsText(blob);
    });
    expect(text).toContain("Ana Pérez");
    expect(text).toContain("anulada");
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:cierre");
    anchorClick.mockRestore();
    await act(async () => root.unmount());
  });

  it("offers no export when the period has nothing to export", async () => {
    loadFinancialClose.mockResolvedValue({
      ok: true,
      data: close({ detail: [], excluded: [], byService: [], totals: { operations: 0, facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 } }),
    });
    const { node, root } = await render();
    expect(Array.from(node.querySelectorAll("button")).some((b) => b.textContent === T.exportar)).toBe(false);
    await act(async () => root.unmount());
  });

  it("shows a retry on a failed load and reloads the same range", async () => {
    loadFinancialClose.mockResolvedValueOnce({ ok: false, error: "load_failed" });
    const { node, root } = await render();
    expect(node.textContent).toContain(T.loadError);

    await click(button(node, T.reintentar));
    expect(loadFinancialClose).toHaveBeenCalledTimes(2);
    expect(lastRange()).toEqual({ desde: "2026-09-21", hasta: "2026-09-27" });
    expect(node.textContent).toContain("3\u202f000 GYD");
    await act(async () => root.unmount());
  });

  // Step 1 of the semantic money colours (odd/tasks/semantic-money-colors.md).
  describe("money tones", () => {
    const tile = (node: Element, label: string) =>
      Array.from(node.querySelectorAll("p")).find((p) => p.textContent === label)!.parentElement as HTMLElement;
    const toneOf = (el: Element | null) => el?.querySelector("[data-tone]")?.getAttribute("data-tone") ?? null;
    const cellTone = (row: Element, index: number) => row.querySelectorAll("td")[index]!.getAttribute("data-tone");

    it("colours the facturado / invertido / retorno tiles blue / amber / green, with a + on the result and a stripe", async () => {
      const { node, root } = await render();

      expect(toneOf(tile(node, T.totales.facturado))).toBe("in");
      expect(toneOf(tile(node, T.totales.invertido))).toBe("out");
      expect(toneOf(tile(node, T.totales.retorno))).toBe("profit");
      expect(tile(node, T.totales.retorno).textContent).toContain("+800 GYD");
      expect(tile(node, T.totales.facturado).textContent).toContain("3\u202f000 GYD");
      expect(tile(node, T.totales.facturado).textContent).not.toContain("+3");
      expect(tile(node, T.totales.facturado).className).toContain("--money-in");
      expect(tile(node, T.totales.retorno).className).toContain("--money-profit");
      // the operations count is not money
      expect(toneOf(tile(node, T.totales.operaciones))).toBeNull();
      expect(tile(node, T.totales.operaciones).className).not.toContain("--money");
      await act(async () => root.unmount());
    });

    it("shows a loss in red with a true minus and a zero result neutral and unsigned", async () => {
      const base = close();
      loadFinancialClose.mockResolvedValue({ ok: true, data: { ...base, totals: { ...base.totals, retornoGyd: -250 } } });
      const loss = await render();
      expect(toneOf(tile(loss.node, T.totales.retorno))).toBe("loss");
      expect(tile(loss.node, T.totales.retorno).textContent).toContain("\u2212250 GYD");
      await act(async () => loss.root.unmount());

      loadFinancialClose.mockResolvedValue({ ok: true, data: { ...base, totals: { ...base.totals, retornoGyd: 0 } } });
      const zero = await render();
      expect(toneOf(tile(zero.node, T.totales.retorno))).toBe("neutral");
      expect(tile(zero.node, T.totales.retorno).textContent).toContain("0 GYD");
      expect(tile(zero.node, T.totales.retorno).textContent).not.toMatch(/[+\u2212]0/);
      await act(async () => zero.root.unmount());
    });

    it("tones only the facturado and retorno cells of the by-service table", async () => {
      const { node, root } = await render();

      const row = node.querySelector("[data-testid='service-row']")!;
      expect([0, 1, 2, 3].map((i) => cellTone(row, i))).toEqual([null, null, "in", "profit"]);
      // the table figures carry no sign
      expect(row.querySelectorAll("td")[3]!.textContent).toContain("500 GYD");
      expect(row.querySelectorAll("td")[3]!.textContent).not.toContain("+");
      await act(async () => root.unmount());
    });

    it("tones the three money columns of the detail table but not the voided entries", async () => {
      const { node, root } = await render();

      const detail = node.querySelector("[data-testid='detail-row']")!;
      expect([5, 7, 8, 9].map((i) => cellTone(detail, i))).toEqual([null, "in", "out", "profit"]);
      const excluded = node.querySelector("[data-testid='excluded-row']")!;
      expect([7, 8, 9].map((i) => cellTone(excluded, i))).toEqual([null, null, null]);
      await act(async () => root.unmount());
    });
  });

  describe("service dots", () => {
    it("puts the fixed dot before the service name in the by-service and detail tables", async () => {
      const { node, root } = await render();

      const rows = [...node.querySelectorAll("[data-testid='service-row']")];
      expect(rows.map((r) => r.querySelector("td [data-service]")?.getAttribute("data-service"))).toEqual(["zelle", "cup"]);
      expect(rows[0]!.querySelector("td")!.textContent).toBe("Zelle");
      const detail = node.querySelector("[data-testid='detail-row']")!;
      expect(detail.querySelectorAll("td")[4]!.textContent).toBe("CUP");
      expect(detail.querySelectorAll("td")[4]!.querySelector("[data-service]")?.getAttribute("data-service")).toBe("cup");
      expect(detail.querySelectorAll("[data-service]")).toHaveLength(1);
      await act(async () => root.unmount());
    });
  });
});
