// @vitest-environment jsdom
// Phase 3 of the CUP inventory: the compact block of the delivery panel. Presentational view (plan / used / hidden) and the
// container that reads GET /api/remittance-operations/{id}/cup-plan and never gets in the way of completing.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../../messages/es.json";
import { mapCupPanel } from "@/lib/cup-inventory/panel";
import { CupPlanBlock, CupPlanView } from "./cup-plan-block";

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

const line = (cardId: string, cardName: string, last4: string, amount: number, rate: number) => ({
  card_id: cardId, card_name: cardName, last4, lot_id: `lot-${cardId}`, amount_cup: amount, lot_rate: rate,
});

const PLAN = {
  state: "plan",
  total_cup: 150000,
  planned_cup: 150000,
  missing_cup: 0,
  cuba_day: "2026-10-15",
  effective_rate: 975,
  beneficiaries: [
    { beneficiary_id: "b1", position: 1, name: "Ana", amount_cup: 100000, missing_cup: 0, lines: [line("A", "Tarjeta A", "1111", 100000, 960)] },
    { beneficiary_id: "b2", position: 2, name: null, amount_cup: 50000, missing_cup: 0, lines: [line("A", "Tarjeta A", "1111", 20000, 960), line("B", "Tarjeta B", "2222", 30000, 1060)] },
  ],
};

const DONE = {
  state: "completed",
  consumed_cup: 100000,
  cup_rate: 987.96,
  lines: [
    { ...line("A", "Tarjeta A", "1111", 70000, 960), consumed_at: "x" },
    { ...line("B", "Tarjeta B", "2222", 30000, 1060), consumed_at: "x" },
  ],
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

const text = (host: HTMLElement) => (host.textContent ?? "").replace(/ /g, " ");

describe("CupPlanView", () => {
  it("before completion: titled as an estimate, one line per beneficiary and card (a straddling beneficiary has two)", async () => {
    const host = await mount(<CupPlanView read={mapCupPanel(PLAN)!} />);
    const t = text(host);
    expect(t).toContain("Transfiere desde (estimado)");
    expect(t).toContain("Ana — 100 000 CUP → Tarjeta A (…1111)");
    expect(t).toContain("Beneficiario 2 — 20 000 CUP → Tarjeta A (…1111)");
    expect(t).toContain("Beneficiario 2 — 30 000 CUP → Tarjeta B (…2222)");
    expect(t).not.toContain("Faltan");
  });

  it("warns, without a button or any blocking, when CUP is left without a card today", async () => {
    const short = mapCupPanel({
      ...PLAN,
      missing_cup: 70000,
      planned_cup: 80000,
      beneficiaries: [{ ...PLAN.beneficiaries[0], amount_cup: 150000, missing_cup: 70000, lines: [line("A", "Tarjeta A", "1111", 80000, 960)] }],
    })!;
    const host = await mount(<CupPlanView read={short} />);
    expect(text(host)).toContain("Faltan 70 000 CUP sin tarjeta con límite hoy: queda para mañana");
    expect(text(host)).toContain("Ana — 70 000 CUP → sin tarjeta con límite hoy");
    expect(host.querySelector("button")).toBeNull();
  });

  it("after completion: where it left from, with each lot's rate, and the resulting rate", async () => {
    const host = await mount(<CupPlanView read={mapCupPanel(DONE)!} />);
    const t = text(host);
    expect(t).toContain("Salió de");
    expect(t).toContain("Tarjeta A (…1111) — 70 000 CUP (lote a 960)");
    expect(t).toContain("Tarjeta B (…2222) — 30 000 CUP (lote a 1 060)");
    expect(t).toContain("Tasa resultante: 987,96 CUP por USDT");
  });

  it("renders nothing for the empty states", async () => {
    for (const state of ["not_cup", "no_inventory", "no_amounts", "unavailable"]) {
      const host = await mount(<CupPlanView read={mapCupPanel({ state })!} />);
      expect(host.textContent).toBe("");
    }
  });
});

describe("CupPlanBlock", () => {
  it("reads the plan of the operation and shows it", async () => {
    const fetchMock = vi.fn(() => Promise.resolve(new Response(JSON.stringify({ cupPlan: mapCupPanel(PLAN) }), { status: 200 })));
    vi.stubGlobal("fetch", fetchMock);
    const host = await mount(<CupPlanBlock operationId="op-1" />);
    expect(fetchMock).toHaveBeenCalledWith("/api/remittance-operations/op-1/cup-plan", expect.objectContaining({ cache: "no-store" }));
    expect(text(host)).toContain("Ana — 100 000 CUP → Tarjeta A (…1111)");
  });

  it("shows nothing (no error, no throw) when the request fails, answers an error or the network is down", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new Response("{}", { status: 500 }))));
    expect((await mount(<CupPlanBlock operationId="op-1" />)).textContent).toBe("");
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new Error("offline"))));
    expect((await mount(<CupPlanBlock operationId="op-1" />)).textContent).toBe("");
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new Response("not json", { status: 200 }))));
    expect((await mount(<CupPlanBlock operationId="op-1" />)).textContent).toBe("");
  });

  it("shows nothing for a non-CUP operation", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new Response(JSON.stringify({ cupPlan: { state: "not_cup" } }), { status: 200 }))));
    expect((await mount(<CupPlanBlock operationId="op-1" />)).textContent).toBe("");
  });
});
