// @vitest-environment jsdom
// The /inventario-cup page: admin-only; lists the sending cards in priority order with balance, what was used today and the
// limit left for the Cuba day, and the FIFO lots with their rate; moving a card saves the changed priorities.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { format } from "date-fns";
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
  id: "lot-a", amountCup: 500000, remainingCup: 500000, rateCupPerUsdt: 960, loadedAt: "2026-10-14T12:00:00Z", note: "compra A", editable: true,
  exhausted: false, adjusted: false, adjustmentNetCup: 0, ...over,
});
const card = (over: Record<string, unknown> = {}) => ({
  id: "card-a", name: "Tarjeta A", last4: "1234", priority: 1, active: true, dailyLimitCup: 120000, balanceCup: 500000,
  usedTodayCup: 0, remainingLimitTodayCup: 120000, lots: [lot()], consumptionsToday: [], ...over,
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

  it("lists today's movements of each card with time, amount, rate and where the CUP went", async () => {
    const movements = [
      { id: "k-2", consumedAt: "2026-10-14T16:00:00Z", amountCup: 15000, lotId: "lot-a", lotRateCupPerUsdt: 960, operationId: null, entryId: "e-2", source: "manual", customerName: "Marlene" },
      { id: "k-1", consumedAt: "2026-10-14T15:30:00Z", amountCup: 50000, lotId: "lot-a", lotRateCupPerUsdt: 960, operationId: "op-1", entryId: "e-1", source: "completed_operation", customerName: "Cliente Uno" },
    ];
    fetchMock.mockImplementation(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ ...REPORT, cards: [card({ usedTodayCup: 65000, consumptionsToday: movements })] }),
    }));
    const node = await mount();
    const text = node.textContent ?? "";

    expect(text).toContain(t.movements.title);
    expect(text).toContain("Cliente Uno");
    expect(text).toContain("Marlene");
    expect(text).toContain(`50${NBSP}000`);
    expect(text).toContain(`15${NBSP}000`);
    expect(text).toContain(format(new Date("2026-10-14T15:30:00Z"), "HH:mm"));
    expect(text).toContain(t.movements.operation);
    expect(text).toContain(t.movements.manual);
    // newest first, as the RPC returns them
    expect(text.indexOf("Marlene")).toBeLessThan(text.indexOf("Cliente Uno"));
    expect(text).not.toContain(t.movements.empty);
  });

  it("a card with no movements today says so", async () => {
    const node = await mount();
    expect(node.textContent).toContain(t.movements.empty);
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

// ---- Migration 256: current balance, adjust dialog, lot history -------------------------------------------------------------------------

/** Types into a controlled React input the way a user does. */
async function type(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

const buttonByText = (text: string) => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as HTMLButtonElement | undefined;

const ELIABA = card({
  id: "card-e",
  name: "Eliaba",
  last4: "6118",
  balanceCup: 222840,
  lots: [
    lot({ id: "lot-old", amountCup: 250000, remainingCup: 0, rateCupPerUsdt: 960, note: "primer lote", editable: false, exhausted: true, adjusted: true, adjustmentNetCup: 12000 }),
    lot({ id: "lot-new", amountCup: 240000, remainingCup: 222840, rateCupPerUsdt: 1015, note: "segundo lote", editable: false }),
  ],
});

describe("Inventario CUP page: current balance and lot history", () => {
  beforeEach(() => {
    fetchMock.mockImplementation(async (url: string, init?: { method?: string }) => ({
      ok: true,
      status: 200,
      json: async () => (!init?.method || init.method === "GET" ? { ...REPORT, cards: [ELIABA] } : {}),
    }));
  });

  it("shows the current balance of the card in green, the same size as the other figures, with the Adjust balance action", async () => {
    const node = await mount();
    const text = node.textContent ?? "";
    const figure = [...node.querySelectorAll("dt")].find((dt) => dt.textContent === t.card.balance) as HTMLElement;
    const limit = [...node.querySelectorAll("dt")].find((dt) => dt.textContent === t.card.dailyLimit) as HTMLElement;

    expect(figure).toBeTruthy();
    expect(figure.nextElementSibling?.textContent).toBe(`222${NBSP}840`);
    // owner 2026-10-20: same size as the other figures (as in production), coloured green
    expect(figure.nextElementSibling?.className).toContain("text-money-profit");
    expect(figure.nextElementSibling?.className).toContain("text-base");
    expect(figure.nextElementSibling?.className).not.toMatch(/text-(2xl|3xl)/);
    expect(limit.nextElementSibling?.className).not.toContain("text-money-profit");
    expect(text).toContain(t.card.adjustBalance);
    expect(buttonByText(t.card.adjustBalance)).toBeTruthy();
  });

  it("lists every lot, the used-up one muted with an Agotado label", async () => {
    const node = await mount();
    const rows = [...node.querySelectorAll("tbody tr")].filter((r) => r.textContent?.includes("lote"));
    const used = rows.find((r) => r.textContent?.includes("primer lote")) as HTMLElement;
    const live = rows.find((r) => r.textContent?.includes("segundo lote")) as HTMLElement;

    expect(rows).toHaveLength(2);
    expect(used.textContent).toContain(t.lots.exhausted);
    expect(used.textContent).toContain(`250${NBSP}000`);
    expect(used.className).toMatch(/text-muted-foreground|opacity/);
    expect(live.textContent).not.toContain(t.lots.exhausted);
    expect(live.textContent).toContain(`222${NBSP}840`);
    expect(live.textContent).toContain(`240${NBSP}000`);
  });

  it("shows adjustments in the movements labelled Ajuste with the reason", async () => {
    fetchMock.mockImplementation(async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        ...REPORT,
        cards: [
          {
            ...ELIABA,
            consumptionsToday: [
              { id: "k-a", consumedAt: "2026-10-14T16:00:00Z", amountCup: 17160, lotId: "lot-new", lotRateCupPerUsdt: 1015, operationId: null, entryId: null, source: null, customerName: null, kind: "ajuste", reason: "conteo real" },
              { id: "k-b", consumedAt: "2026-10-14T15:00:00Z", amountCup: 5000, lotId: "lot-new", lotRateCupPerUsdt: 1015, operationId: "op-1", entryId: "e-1", source: "completed_operation", customerName: "Cliente Uno", kind: "operacion", reason: null },
            ],
          },
        ],
      }),
    }));
    const node = await mount();
    const text = node.textContent ?? "";

    expect(text).toContain(t.movements.adjustment);
    expect(text).toContain("conteo real");
    expect(text).toContain("Cliente Uno");
    expect(text).toContain(t.movements.operation);
    expect(text).toContain(`17${NBSP}160`);
  });

  it("Adjust balance opens a dialog with the current balance; it submits only a changed, valid balance and shows the live difference", async () => {
    const node = await mount();
    await act(async () => buttonByText(t.card.adjustBalance)!.click());
    await act(async () => {});

    const dialog = document.querySelector('[role="dialog"]') as HTMLElement;
    expect(dialog.textContent).toContain(t.balanceForm.current);
    expect(dialog.textContent).toContain(`222${NBSP}840`);
    const submit = () => buttonByText(t.balanceForm.submit)!;
    const input = dialog.querySelector("#cup-balance-value") as HTMLInputElement;
    expect(input).toBeTruthy();

    // unchanged / empty / invalid -> disabled
    expect(submit().disabled).toBe(true);
    await type(input, "222.840");
    expect(submit().disabled).toBe(true);
    await type(input, "abc");
    expect(submit().disabled).toBe(true);

    // a Spanish-typed lower balance: the difference shows live, the button is enabled
    await type(input, "200 000");
    expect(submit().disabled).toBe(false);
    expect(dialog.textContent).toContain(t.balanceForm.difference);
    expect(dialog.textContent).toContain(`\u221222${NBSP}840`);
    await type(input, "250,000");
    expect(dialog.textContent).toContain(`+27${NBSP}160`);

    const reason = dialog.querySelector("#cup-balance-reason") as HTMLInputElement;
    await type(input, "222.000");
    await type(reason, "conteo real");
    await act(async () => submit().click());
    await act(async () => {});

    const posts = fetchMock.mock.calls.filter(([, init]) => init?.method === "POST");
    expect(posts).toHaveLength(1);
    expect(posts[0][0]).toBe("/api/inventario-cup/cards/card-e/balance");
    expect(JSON.parse(posts[0][1].body)).toEqual({ balanceCup: 222000, reason: "conteo real" });
    // closed and reloaded
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(fetchMock.mock.calls.filter(([, init]) => !init?.method).length).toBeGreaterThanOrEqual(2);
    node.remove();
  });

  it("zero is allowed and no reason is sent when it is blank", async () => {
    await mount();
    await act(async () => buttonByText(t.card.adjustBalance)!.click());
    await act(async () => {});
    const input = document.querySelector("#cup-balance-value") as HTMLInputElement;
    await type(input, "0");
    await act(async () => buttonByText(t.balanceForm.submit)!.click());
    await act(async () => {});

    const post = fetchMock.mock.calls.find(([, init]) => init?.method === "POST")!;
    expect(JSON.parse(post[1].body)).toEqual({ balanceCup: 0 });
  });

  it("a server refusal stays in the dialog as an error and nothing closes", async () => {
    fetchMock.mockImplementation(async (url: string, init?: { method?: string }) => {
      if (init?.method === "POST") {
        return { ok: false, status: 400, json: async () => ({ error: "the balance cannot exceed what was loaded on the card (490000 CUP): load a new lot" }) };
      }
      return { ok: true, status: 200, json: async () => ({ ...REPORT, cards: [ELIABA] }) };
    });
    await mount();
    await act(async () => buttonByText(t.card.adjustBalance)!.click());
    await act(async () => {});
    await type(document.querySelector("#cup-balance-value") as HTMLInputElement, "900000");
    await act(async () => buttonByText(t.balanceForm.submit)!.click());
    await act(async () => {});

    const dialog = document.querySelector('[role="dialog"]') as HTMLElement;
    expect(dialog).toBeTruthy();
    expect(dialog.querySelector('[role="alert"]')?.textContent).toContain("load a new lot");
  });

  it("cancelling the dialog sends nothing", async () => {
    await mount();
    await act(async () => buttonByText(t.card.adjustBalance)!.click());
    await act(async () => {});
    await act(async () => buttonByText(t.actions.cancel)!.click());
    await act(async () => {});

    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "POST")).toBe(false);
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  });
});

