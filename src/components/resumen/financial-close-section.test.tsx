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
    expect(text).toContain("3,000 GYD");
    expect(text).toContain("2,200 GYD");
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

  it("shows a retry on a failed load and reloads the same range", async () => {
    loadFinancialClose.mockResolvedValueOnce({ ok: false, error: "load_failed" });
    const { node, root } = await render();
    expect(node.textContent).toContain(T.loadError);

    await click(button(node, T.reintentar));
    expect(loadFinancialClose).toHaveBeenCalledTimes(2);
    expect(lastRange()).toEqual({ desde: "2026-09-21", hasta: "2026-09-27" });
    expect(node.textContent).toContain("3,000 GYD");
    await act(async () => root.unmount());
  });
});
