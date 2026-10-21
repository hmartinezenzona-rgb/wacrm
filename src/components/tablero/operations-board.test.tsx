// @vitest-environment jsdom
// The read-only operations board: columns with counts, cards, the missing
// recipient hint, the link to the chat and the service filter.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import type { BoardOperation } from "@/lib/tablero/board";

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

afterEach(() => document.body.replaceChildren());

const NOW = new Date("2026-10-05T12:00:00Z");
const t = en.Tablero;
const n = en.ServiceNames;

function op(over: Partial<BoardOperation> = {}): BoardOperation {
  return {
    operationId: "op-1", conversationId: "conv-1", contactName: "Ana Perez", contactPhone: "5920000000",
    serviceType: "remesa", deliveryMethod: "zelle", status: "collecting_information", quotedSourceAmount: 30000,
    sourceCurrency: "GYD", createdAt: "2026-10-05T09:00:00Z", completedAt: null, stateSince: "2026-10-05T10:00:00Z",
    beneficiariesComplete: true, ...over,
  };
}

async function render(operations: BoardOperation[], filter: "all" | "remesa" | "recarga" | "combo" | "visa" | "saldo" = "all", onFilterChange = vi.fn()) {
  const { OperationsBoard } = await import("./operations-board");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsBoard operations={operations} filter={filter} onFilterChange={onFilterChange} now={NOW} />));
  return { node, onFilterChange };
}

const column = (node: Element, label: string) =>
  Array.from(node.querySelectorAll("section")).find((s) => s.querySelector("h2")?.textContent?.includes(label)) as HTMLElement;

describe("OperationsBoard", () => {
  it("renders the five columns in order, each with its count", async () => {
    const { node } = await render([
      op({ operationId: "a" }),
      op({ operationId: "b", status: "deposit_verification" }),
      op({ operationId: "c", status: "ready_to_transfer" }),
      op({ operationId: "d", status: "transferring" }),
      op({ operationId: "e", status: "incident" }),
      op({ operationId: "f", status: "completed", completedAt: "2026-10-05T11:00:00Z", stateSince: "2026-10-05T11:00:00Z" }),
    ]);
    const headings = Array.from(node.querySelectorAll("section h2")).map((h) => h.textContent);
    expect(headings).toEqual([
      `${t.columns.requested}1`, `${t.columns.depositCheck}1`, `${t.columns.readyToTransfer}2`, `${t.columns.completed}1`, `${t.columns.incident}1`,
    ]);
    expect(column(node, t.columns.readyToTransfer).querySelectorAll("a").length).toBe(2);
    expect(column(node, t.columns.completed).querySelectorAll("a").length).toBe(1);
  });

  it("shows name, service, amount in GYD, time in state, and links the whole card to the chat", async () => {
    const { node } = await render([op()]);
    const card = node.querySelector("a")!;
    expect(card.getAttribute("href")).toBe("/inbox?c=conv-1");
    expect(card.textContent).toContain("Ana Perez");
    expect(card.textContent).toContain(n.zelle);
    expect(card.textContent?.replace(/\u00a0/g, " ")).toContain("GYD 30\u202f000");
    expect(card.textContent).toContain("2 h");
  });

  it("names a remittance by its rail: CUP, Zelle, mixed, and the generic remittance when the rail is unknown", async () => {
    const { node } = await render([
      op({ operationId: "a", deliveryMethod: "cuban_card" }),
      op({ operationId: "b", deliveryMethod: "multiple_distribution" }),
      op({ operationId: "c", deliveryMethod: null }),
    ]);
    const text = Array.from(node.querySelectorAll("a")).map((a) => a.textContent);
    expect(text[0]).toContain(n.cup);
    expect(text[1]).toContain(n.mixed);
    expect(text[2]).toContain(n.remesa);
  });

  it("falls back to the phone, then to a placeholder, when the contact has no name", async () => {
    const { node } = await render([op({ contactName: null }), op({ operationId: "x", contactName: null, contactPhone: null })]);
    const cards = Array.from(node.querySelectorAll("a"));
    expect(cards[0].textContent).toContain("5920000000");
    expect(cards[1].textContent).toContain(t.unknownContact);
  });

  it("shows the missing-recipient hint only where recipients are needed", async () => {
    const { node } = await render([
      op({ operationId: "r", beneficiariesComplete: false }),
      op({ operationId: "v", serviceType: "visa", beneficiariesComplete: false }),
      op({ operationId: "ok", beneficiariesComplete: true }),
    ]);
    const cards = Array.from(node.querySelectorAll("a"));
    expect(cards[0].textContent).toContain(t.missingBeneficiaries);
    expect(cards[1].textContent).not.toContain(t.missingBeneficiaries);
    expect(cards[2].textContent).not.toContain(t.missingBeneficiaries);
  });

  it("labels each service, including recharge and combo", async () => {
    const { node } = await render([op({ serviceType: "recarga" }), op({ operationId: "c", serviceType: "combo" }), op({ operationId: "v", serviceType: "visa" })]);
    const text = Array.from(node.querySelectorAll("a")).map((a) => a.textContent);
    expect(text[0]).toContain(n.recarga);
    expect(text[1]).toContain(n.combo);
    expect(text[2]).toContain(n.visa);
  });

  it("labels a mobile balance as plain text and offers its filter", async () => {
    const { node, onFilterChange } = await render([op({ operationId: "s", serviceType: "saldo", beneficiariesComplete: false })]);
    const card = node.querySelector("a")!;
    expect(card.textContent).toContain(n.saldo);
    expect(card.textContent).toContain(t.missingBeneficiaries);
    expect(card.querySelector("svg")).toBeNull();
    const saldo = Array.from(node.querySelectorAll("button")).find((b) => b.textContent === n.saldo)!;
    await act(async () => saldo.click());
    expect(onFilterChange).toHaveBeenCalledWith("saldo");
  });

  it("filters by service and notifies the change", async () => {
    const { node, onFilterChange } = await render(
      [op({ operationId: "r" }), op({ operationId: "c", serviceType: "combo" })],
      "combo",
    );
    expect(node.querySelectorAll("a").length).toBe(1);
    expect(column(node, t.columns.requested).querySelector("h2")!.textContent).toContain("1");
    const visa = Array.from(node.querySelectorAll("button")).find((b) => b.textContent === n.visa)!;
    await act(async () => visa.click());
    expect(onFilterChange).toHaveBeenCalledWith("visa");
    const pressed = Array.from(node.querySelectorAll("button")).filter((b) => b.getAttribute("aria-pressed") === "true");
    expect(pressed.map((b) => b.textContent)).toEqual([n.combo]);
  });

  it("offers no control that changes an operation", async () => {
    const { node } = await render([op()]);
    const buttons = Array.from(node.querySelectorAll("button")).map((b) => b.textContent);
    expect(buttons).toEqual([t.filters.all, n.remesa, n.recarga, n.combo, n.visa, n.saldo]);
    expect(node.querySelector("[draggable='true']")).toBeNull();
  });

  describe("visual pass", () => {
    const COLUMN_TONES: Array<[string, string, string]> = [
      ["requested", "collecting_information", "neutral"],
      ["depositCheck", "deposit_verification", "attention"],
      ["readyToTransfer", "ready_to_transfer", "attention"],
      ["completed", "completed", "success"],
      ["incident", "incident", "danger"],
    ];

    it.each(COLUMN_TONES)("tints the %s column header (status %s) and stripes it with the %s tone", async (id, status, tone) => {
      const { node } = await render([op({ status, completedAt: status === "completed" ? "2026-10-05T11:00:00Z" : null })]);
      const heading = column(node, t.columns[id as keyof typeof t.columns]).querySelector("h2")!;
      const soft = tone === "neutral" ? "bg-muted" : `bg-status-${tone}-soft`;
      const stripe = tone === "neutral" ? "bg-muted-foreground" : `bg-status-${tone}`;
      expect(heading.classList.contains(soft)).toBe(true);
      expect(heading.querySelector(`[data-stripe].${stripe}`)).not.toBeNull();
      expect(heading.innerHTML).not.toMatch(/amber-500|emerald-500|red-500|bg-primary/);
    });

    it("stripes a card with the tone of its own status, not of its column", async () => {
      const { node } = await render([op({ status: "transferring" }), op({ operationId: "c", status: "ready_to_transfer" })]);
      const cards = Array.from(column(node, t.columns.readyToTransfer).querySelectorAll("a"));
      expect(cards[0].querySelector("[data-stripe]")!.className).toContain("bg-status-info");
      expect(cards[1].querySelector("[data-stripe]")!.className).toContain("bg-status-attention");
    });

    it("sets the lane darker than the card with a border, and gives the card a light elevation", async () => {
      const { node } = await render([op()]);
      const lane = column(node, t.columns.requested);
      const card = lane.querySelector("a")!;
      expect(lane.classList.contains("bg-lane")).toBe(true);
      expect(card.className).toContain("bg-card");
      expect(card.className).toContain("shadow-[var(--elev-card)]");
      expect(card.className).toContain("focus-visible:ring-2");
    });

    it("shows the amount larger and bold", async () => {
      const { node } = await render([op()]);
      const amount = Array.from(node.querySelectorAll("a span")).find((e) => e.textContent?.includes("30"))!;
      expect(amount.className).toContain("font-bold");
      expect(amount.className).toContain("text-base");
    });

    it.each([
      ["1 h 59 min", "2026-10-05T10:01:00Z", "collecting_information", "text-muted-foreground"],
      ["2 h", "2026-10-05T10:00:00Z", "collecting_information", "text-status-attention"],
      ["23 h 59 min", "2026-10-04T12:01:00Z", "collecting_information", "text-status-attention"],
      ["24 h", "2026-10-04T12:00:00Z", "collecting_information", "text-status-danger"],
      ["a completed operation after 3 days", "2026-10-02T12:00:00Z", "completed", "text-muted-foreground"],
    ])("colours the age of %s", async (_label, stateSince, status, cls) => {
      const { node } = await render([op({ stateSince, status })]);
      const age = node.querySelector("a [title]")!;
      expect(age.className).toContain(cls);
      expect(age.getAttribute("title")).toContain(age.textContent!);
    });

    it("draws the missing-recipient line with the attention tone and a dot, not a triangle", async () => {
      const { node } = await render([op({ beneficiariesComplete: false })]);
      const line = Array.from(node.querySelectorAll("a p")).find((p) => p.textContent === t.missingBeneficiaries)!;
      expect(line.className).toContain("text-status-attention");
      expect(line.querySelector("svg")).toBeNull();
      expect(line.querySelector("[data-dot]")).not.toBeNull();
      expect(line.className).not.toMatch(/amber/);
    });

    it("has no service icon on the card", async () => {
      const { node } = await render([op({ serviceType: "recarga" }), op({ operationId: "z", deliveryMethod: "cuban_card" })]);
      expect(node.querySelectorAll("a svg").length).toBe(0);
    });
  });
});
