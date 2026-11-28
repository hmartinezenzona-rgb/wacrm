// @vitest-environment jsdom
// The Clásica / Tropical block of the delivery panel: presentational view (plan / blocked / used / hidden) and the container that
// reads GET /api/remittance-operations/{id}/usd-plan, reports a blocked plan and never gets in the way of completing.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../../messages/es.json";
import { mapUsdPanel } from "@/lib/usd-inventory/panel";
import { UsdPlanBlock, UsdPlanView } from "./usd-plan-block";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, es as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const line = (over: Record<string, unknown> = {}) => ({
  card_id: "c1", card_name: "Clásica A", last4: "1234", lot_id: "l1", amount_usd: 100, usd_per_usdt: 1.05, ...over,
});
const service = (over: Record<string, unknown> = {}) => ({
  service: "CLASICA", needed_usd: 100, planned_usd: 100, missing_usd: 0, blocked: false, invested_usdt: 95.24, lines: [line()], cards: [], ...over,
});
const PLAN = { state: "plan", operation_id: "op", estimate: true, cuba_month: "2026-11-01", blocked: false, services: [service()] };
const BLOCKED = {
  ...PLAN,
  blocked: true,
  services: [service({ service: "TROPICAL", needed_usd: 400, planned_usd: 250, missing_usd: 150, blocked: true, lines: [line({ card_name: "Tropical A", last4: null, amount_usd: 250 })] })],
};
const DONE = {
  state: "completed", operation_id: "op", estimate: false, consumed_usd: 100, invested_usdt: 95.24, cost_gyd: 22666.67, shortfall_usd: 0,
  lines: [{ ...line(), service: "CLASICA", consumed_at: "x" }, { ...line({ card_id: "c2", card_name: "Clásica B", usd_per_usdt: 1 }), service: "CLASICA", consumed_at: "x" }],
};

async function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(node);
  });
  await act(async () => {
    await Promise.resolve();
  });
  return host;
}
const text = (host: HTMLElement) => (host.textContent ?? "").replace(/[  ]/g, " ");

describe("UsdPlanView", () => {
  it("before completion: labelled as an estimate, one row per line with card, last4, USD and the lot discount", async () => {
    const host = await mount(<UsdPlanView read={mapUsdPanel(PLAN)!} />);
    const t = text(host);
    expect(t).toContain("Sale de (estimado)");
    expect(t).toContain("Clásica A ···· 1234: 100 USD (lote al 5%)");
    expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("a 1x1 lot reads 'lote 1x1'; a card without last4 skips the digits", async () => {
    const read = mapUsdPanel({ ...PLAN, services: [service({ lines: [line({ usd_per_usdt: 1, last4: null })] })] })!;
    const t = text(await mount(<UsdPlanView read={read} />));
    expect(t).toContain("Clásica A: 100 USD (lote 1x1)");
  });

  it("blocked: a clear red message with the missing USD and the service, plus what is available", async () => {
    const host = await mount(<UsdPlanView read={mapUsdPanel(BLOCKED)!} />);
    const alert = host.querySelector('[role="alert"]') as HTMLElement;
    expect(alert.textContent).toBe("Faltan 150 USD en Tropical: compra saldo antes de completar");
    expect(alert.className).toMatch(/text-red/);
    expect(text(host)).toContain("Tropical A: 250 USD");
  });

  it("after completion: the lines that really left and the real USDT cost", async () => {
    const host = await mount(<UsdPlanView read={mapUsdPanel(DONE)!} />);
    const t = text(host);
    expect(t).toContain("Salió de");
    expect(t).toContain("Clásica A ···· 1234: 100 USD (lote al 5%)");
    expect(t).toContain("Clásica B ···· 1234: 100 USD (lote 1x1)");
    expect(t).toContain("Costo real: 95,24 USDT");
    expect(t).not.toContain("estimado");
    expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("after completion with a shortfall: one amber note", async () => {
    const host = await mount(<UsdPlanView read={mapUsdPanel({ ...DONE, shortfall_usd: 30 })!} />);
    expect(text(host)).toContain("No había saldo para 30 USD");
  });

  it("renders nothing for the empty states", async () => {
    for (const state of ["not_usd", "no_inventory", "no_amounts", "unavailable"]) {
      expect((await mount(<UsdPlanView read={mapUsdPanel({ state })!} />)).textContent).toBe("");
    }
  });
});

describe("UsdPlanBlock", () => {
  const respond = (body: unknown, status = 200) => vi.fn(() => Promise.resolve(new Response(JSON.stringify(body), { status })));

  it("reads the plan of the operation and shows it", async () => {
    const fetchMock = respond({ usdPlan: mapUsdPanel(PLAN) });
    vi.stubGlobal("fetch", fetchMock);
    const host = await mount(<UsdPlanBlock operationId="op-1" />);
    expect(fetchMock).toHaveBeenCalledWith("/api/remittance-operations/op-1/usd-plan", expect.objectContaining({ cache: "no-store" }));
    expect(text(host)).toContain("Clásica A");
  });

  it("tells the container when the plan is blocked, and when it is not", async () => {
    vi.stubGlobal("fetch", respond({ usdPlan: mapUsdPanel(BLOCKED) }));
    const onBlockedChange = vi.fn();
    await mount(<UsdPlanBlock operationId="op-1" onBlockedChange={onBlockedChange} />);
    expect(onBlockedChange).toHaveBeenLastCalledWith(true);

    vi.stubGlobal("fetch", respond({ usdPlan: mapUsdPanel(PLAN) }));
    const ok = vi.fn();
    await mount(<UsdPlanBlock operationId="op-2" onBlockedChange={ok} />);
    expect(ok).toHaveBeenLastCalledWith(false);
  });

  it("shows nothing and never blocks when the request fails, errors, is not JSON or the operation is not USD", async () => {
    const blocked = vi.fn();
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new Response("{}", { status: 500 }))));
    expect((await mount(<UsdPlanBlock operationId="op-1" onBlockedChange={blocked} />)).textContent).toBe("");
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new Error("offline"))));
    expect((await mount(<UsdPlanBlock operationId="op-1" onBlockedChange={blocked} />)).textContent).toBe("");
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new Response("not json", { status: 200 }))));
    expect((await mount(<UsdPlanBlock operationId="op-1" onBlockedChange={blocked} />)).textContent).toBe("");
    vi.stubGlobal("fetch", respond({ usdPlan: { state: "not_usd" } }));
    expect((await mount(<UsdPlanBlock operationId="op-1" onBlockedChange={blocked} />)).textContent).toBe("");
    expect(blocked).not.toHaveBeenCalledWith(true);
  });
});
