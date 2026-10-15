// @vitest-environment jsdom
// The /inventario-cup page: admin-only; lists the sending cards in priority order with balance, what was used today and the
// limit left for the Cuba day, and the FIFO lots with their rate; moving a card saves the changed priorities.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, values?: Record<string, string | number>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      return raw.replace(/\{(\w+)\}/g, (_, k) => String(values?.[k]));
    };
  },
}));

const auth = { profileLoading: false, accountRole: "admin" as string | null };
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => auth }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

const fetchMock = vi.fn();
const t = en.CupInventory;
const NBSP = " ";

const lot = (over: Record<string, unknown> = {}) => ({
  id: "lot-a", amountCup: 500000, remainingCup: 500000, rateCupPerUsdt: 960, loadedAt: "2026-10-14T12:00:00Z", note: "compra A", editable: true, ...over,
});
const card = (over: Record<string, unknown> = {}) => ({
  id: "card-a", name: "Tarjeta A", last4: "1234", priority: 1, active: true, dailyLimitCup: 120000, balanceCup: 500000,
  usedTodayCup: 0, remainingLimitTodayCup: 120000, lots: [lot()], ...over,
});
const REPORT = {
  cubaDay: "2026-10-14",
  cards: [
    card(),
    card({ id: "card-b", name: "Tarjeta B", last4: null, priority: 2, balanceCup: 250000, lots: [lot({ id: "lot-b", amountCup: 250000, remainingCup: 250000, rateCupPerUsdt: 1060, note: null })] }),
  ],
};

beforeEach(() => {
  auth.profileLoading = false;
  auth.accountRole = "admin";
  fetchMock.mockReset();
  fetchMock.mockImplementation(async (url: string, init?: { method?: string }) => ({
    ok: true,
    status: 200,
    json: async () => (!init?.method || init.method === "GET" ? REPORT : {}),
  }));
  vi.stubGlobal("fetch", fetchMock);
});
const mounted: Array<{ unmount: () => void }> = [];

afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((r) => r.unmount()));
  document.body.replaceChildren();
  vi.unstubAllGlobals();
});

async function mount() {
  const { default: Page } = await import("./page");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<Page />));
  await act(async () => {});
  mounted.push(root);
  return node;
}

describe("Inventario CUP page", () => {
  it("lists the cards in priority order with balance, limit left today and the lots with their rate", async () => {
    const node = await mount();
    const text = node.textContent ?? "";

    expect(fetchMock.mock.calls[0][0]).toContain("/api/inventario-cup");
    expect(text.indexOf("Tarjeta A")).toBeGreaterThan(-1);
    expect(text.indexOf("Tarjeta A")).toBeLessThan(text.indexOf("Tarjeta B"));
    expect(text).toContain(`500${NBSP}000`);
    expect(text).toContain(`250${NBSP}000`);
    expect(text).toContain(`120${NBSP}000`);
    expect(text).toContain("960");
    expect(text).toContain(`1${NBSP}060`);
    expect(text).toContain("1234");
    expect(text).toContain("compra A");
    expect(text).toContain("14/10/2026");
    expect(text).toContain(t.card.remainingToday);
  });

  it("moving the first card down saves the two changed priorities", async () => {
    const node = await mount();
    const down = node.querySelector(`button[aria-label="${t.card.moveDown}"]`) as HTMLButtonElement;
    await act(async () => down.click());
    await act(async () => {});

    const patches = fetchMock.mock.calls
      .filter(([, init]) => init?.method === "PATCH")
      .map(([url, init]) => [url, JSON.parse(init.body)]);
    expect(patches).toEqual([
      ["/api/inventario-cup/cards/card-b", { priority: 1 }],
      ["/api/inventario-cup/cards/card-a", { priority: 2 }],
    ]);
  });

  it("the first card cannot go up and the last cannot go down", async () => {
    const node = await mount();
    const ups = [...node.querySelectorAll(`button[aria-label="${t.card.moveUp}"]`)] as HTMLButtonElement[];
    const downs = [...node.querySelectorAll(`button[aria-label="${t.card.moveDown}"]`)] as HTMLButtonElement[];
    expect(ups[0].disabled).toBe(true);
    expect(ups[1].disabled).toBe(false);
    expect(downs[0].disabled).toBe(false);
    expect(downs[1].disabled).toBe(true);
  });

  it("deleting a lot asks in a dialog, not a browser prompt, and only deletes after confirming", async () => {
    const confirmSpy = vi.fn(() => true);
    vi.stubGlobal("confirm", confirmSpy);
    const node = await mount();
    const del = node.querySelector(`button[aria-label="${t.lots.delete}"]`) as HTMLButtonElement;
    await act(async () => del.click());
    await act(async () => {});

    expect(confirmSpy).not.toHaveBeenCalled();
    expect(document.body.textContent).toContain(t.lots.confirmDelete);
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(false);

    const confirmButton = [...document.querySelectorAll("button")].find(
      (b) => b.textContent === t.actions.delete,
    ) as HTMLButtonElement;
    await act(async () => confirmButton.click());
    await act(async () => {});

    const deletes = fetchMock.mock.calls.filter(([, init]) => init?.method === "DELETE").map(([url]) => url);
    expect(deletes).toEqual(["/api/inventario-cup/lots/lot-a"]);
  });

  it("cancelling the delete dialog deletes nothing", async () => {
    const node = await mount();
    const del = node.querySelector(`button[aria-label="${t.lots.delete}"]`) as HTMLButtonElement;
    await act(async () => del.click());
    await act(async () => {});
    const cancel = [...document.querySelectorAll("button")].find(
      (b) => b.textContent === t.actions.cancel,
    ) as HTMLButtonElement;
    await act(async () => cancel.click());
    await act(async () => {});

    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(false);
    expect(document.body.textContent).not.toContain(t.lots.confirmDelete);
  });

  it("a lot already used shows no edit or delete actions", async () => {
    fetchMock.mockImplementation(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ ...REPORT, cards: [card({ lots: [lot({ editable: false, remainingCup: 400000 })] })] }),
    }));
    const node = await mount();
    expect(node.querySelector(`button[aria-label="${t.lots.delete}"]`)).toBeNull();
    expect(node.querySelector(`button[aria-label="${t.lots.edit}"]`)).toBeNull();
  });

  it("an agent sees the forbidden message and nothing is fetched", async () => {
    auth.accountRole = "agent";
    const node = await mount();
    expect(node.textContent).toContain(t.forbidden);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("shows the empty state when there are no cards", async () => {
    fetchMock.mockImplementation(async () => ({ ok: true, status: 200, json: async () => ({ cubaDay: "2026-10-14", cards: [] }) }));
    const node = await mount();
    expect(node.textContent).toContain(t.empty);
  });

  it("a failed load shows the error", async () => {
    fetchMock.mockImplementation(async () => ({ ok: false, status: 500, json: async () => ({}) }));
    const node = await mount();
    expect(node.textContent).toContain(t.loadError);
  });
});
