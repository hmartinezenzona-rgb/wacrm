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

const norm = (s: string | null) => (s ?? "").replace(/\u202f/g, " ");
const text = (host: HTMLElement) => (host.textContent ?? "").replace(/ /g, " ");

describe("CupPlanView", () => {
  it("before completion: grouped by card, card header with total, indented beneficiary rows", async () => {
    const host = await mount(<CupPlanView read={mapCupPanel(PLAN)!} />);
    const t = text(host);
    expect(t).toContain("Transfiere desde · estimado");
    const cards = [...host.querySelectorAll('[data-testid="cup-plan-card"]')].map((c) => norm(c.textContent));
    expect(cards).toHaveLength(2);
    expect(cards[0]).toContain("Tarjeta A");
    expect(cards[0]).toContain("·1111");
    expect(cards[0]).toContain("120 000 CUP");
    expect(cards[0]).toContain("→ Ana");
    expect(cards[0]).toContain("→ Beneficiario 2");
    expect(cards[1]).toContain("Tarjeta B");
    expect(cards[1]).toContain("30 000 CUP");
    expect(t).not.toContain("Faltan");
    expect(host.querySelector("[role=status]")).toBeNull();
  });

  it("warns, without a button or any blocking, with one line per beneficiary short of CUP", async () => {
    const short = mapCupPanel({
      ...PLAN,
      missing_cup: 90000,
      beneficiaries: [
        { ...PLAN.beneficiaries[0], amount_cup: 150000, missing_cup: 70000, lines: [line("A", "Tarjeta A", "1111", 80000, 960)] },
        { ...PLAN.beneficiaries[1], amount_cup: 50000, missing_cup: 20000, lines: [line("A", "Tarjeta A", "1111", 30000, 960)] },
      ],
    })!;
    const host = await mount(<CupPlanView read={short} />);
    const warn = host.querySelector("[role=status]");
    expect(warn).not.toBeNull();
    const w = norm(warn!.textContent);
    expect(w).toContain("Faltan 70 000 CUP (Ana)");
    expect(w).toContain("Faltan 20 000 CUP (Beneficiario 2)");
    expect(w).toContain("Sin tarjeta con límite hoy · queda para mañana");
    expect(w.match(/Sin tarjeta/g)).toHaveLength(1);
    expect(host.querySelector("button")).toBeNull();
  });

  it("after completion: grouped by card with lot-rate rows, and the resulting rate at the bottom", async () => {
    const host = await mount(<CupPlanView read={mapCupPanel(DONE)!} />);
    const t = text(host);
    expect(t).toContain("Salió de");
    const cards = [...host.querySelectorAll('[data-testid="cup-used-card"]')].map((c) => norm(c.textContent));
    expect(cards).toHaveLength(2);
    expect(cards[0]).toContain("Tarjeta A");
    expect(cards[0]).toContain("·1111");
    expect(cards[0]).toContain("70 000 CUP");
    expect(cards[0]).toContain("a 960 CUP/USDT");
    expect(cards[1]).toContain("a 1 060 CUP/USDT");
    expect(t).toContain("Tasa resultante: 987,96");
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
    expect(text(host)).toContain("→ Ana");
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
