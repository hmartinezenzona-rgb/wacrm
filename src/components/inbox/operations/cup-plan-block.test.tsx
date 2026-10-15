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
  it("before completion: a plain title and one row per card with its total, no beneficiary rows", async () => {
    const host = await mount(<CupPlanView read={mapCupPanel(PLAN)!} />);
    const t = text(host);
    expect(t).toContain("Transferir desde");
    expect(t).not.toContain("estimado");
    expect(host.querySelector("p")?.className).not.toContain("uppercase");
    const cards = [...host.querySelectorAll('[data-testid="cup-plan-card"]')].map((c) => norm(c.textContent));
    expect(cards).toEqual(["Tarjeta A ·1111120 000 CUP", "Tarjeta B ·222230 000 CUP"]);
    expect(t).not.toContain("→");
    expect(t).not.toContain("Ana");
    expect(t).not.toContain("Faltan");
    expect(host.querySelector("[role=status]")).toBeNull();
  });

  it("warns with one plain line and a dot (no icon, no box) with the total CUP missing", async () => {
    const short = mapCupPanel({
      ...PLAN,
      missing_cup: 90000,
      beneficiaries: [
        { ...PLAN.beneficiaries[0], amount_cup: 150000, missing_cup: 70000, lines: [line("A", "Tarjeta A", "1111", 80000, 960)] },
        { ...PLAN.beneficiaries[1], amount_cup: 50000, missing_cup: 20000, lines: [line("A", "Tarjeta A", "1111", 30000, 960)] },
      ],
    })!;
    const host = await mount(<CupPlanView read={short} />);
    const warn = host.querySelector("[role=status]") as HTMLElement;
    expect(warn).not.toBeNull();
    expect(norm(warn.textContent)).toBe("Faltan 90 000 CUP · queda para mañana");
    expect(warn.className).toContain("text-amber");
    expect(warn.className).not.toMatch(/\bbg-|border|rounded-md|\bp[xy]?-/);
    expect(warn.querySelector("svg")).toBeNull();
    expect(warn.querySelector('[data-testid="cup-plan-dot"]')).not.toBeNull();
    expect(host.querySelector("button")).toBeNull();
  });

  it("after completion: title and one row per card with its total, no lot rates, no resulting rate", async () => {
    const host = await mount(<CupPlanView read={mapCupPanel(DONE)!} />);
    const t = text(host);
    expect(t).toContain("Salió de");
    const cards = [...host.querySelectorAll('[data-testid="cup-used-card"]')].map((c) => norm(c.textContent));
    expect(cards).toEqual(["Tarjeta A ·111170 000 CUP", "Tarjeta B ·222230 000 CUP"]);
    expect(t).not.toContain("CUP/USDT");
    expect(t).not.toContain("Tasa resultante");
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
    expect(text(host)).toContain("Tarjeta A");
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
