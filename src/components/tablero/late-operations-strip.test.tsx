// @vitest-environment jsdom
// The "Atrasadas" strip above the board: the stalest in-flight operations with a link to their chat.

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

const setInboxOpenTarget = vi.hoisted(() => vi.fn());
vi.mock("@/lib/inbox/open-target", () => ({ setInboxOpenTarget }));

afterEach(() => {
  document.body.replaceChildren();
  setInboxOpenTarget.mockClear();
});

const NOW = new Date("2026-10-05T12:00:00Z");
const hoursAgo = (h: number) => new Date(NOW.getTime() - h * 3_600_000).toISOString();
const t = en.Tablero;

function op(over: Partial<BoardOperation> = {}): BoardOperation {
  return {
    operationId: "op-1", conversationId: "conv-1", contactName: "Ana Perez", contactPhone: "5920000000",
    serviceType: "remesa", deliveryMethod: "zelle", status: "ready_to_transfer", quotedSourceAmount: 30000,
    sourceCurrency: "GYD", createdAt: hoursAgo(80), completedAt: null, stateSince: hoursAgo(50),
    beneficiariesComplete: true, ...over,
  };
}

async function render(operations: BoardOperation[]) {
  const { LateOperationsStrip } = await import("./late-operations-strip");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<LateOperationsStrip operations={operations} now={NOW} />));
  return node;
}

describe("LateOperationsStrip", () => {
  it("renders nothing when no operation is late", async () => {
    const node = await render([op({ stateSince: hoursAgo(3) }), op({ operationId: "d", status: "completed", stateSince: hoursAgo(90) })]);
    expect(node.innerHTML).toBe("");
  });

  it("lists late operations oldest first with name, service, amount and age", async () => {
    const node = await render([
      op({ operationId: "new", contactName: "Beto", stateSince: hoursAgo(30) }),
      op({ operationId: "old", contactName: "Ana Perez", stateSince: hoursAgo(50) }),
      op({ operationId: "ok", contactName: "Fresh", stateSince: hoursAgo(1) }),
    ]);
    expect(node.querySelector("h2")!.textContent).toBe(t.late.title);
    const rows = Array.from(node.querySelectorAll("li"));
    expect(rows.length).toBe(2);
    expect(rows[0].textContent).toContain("Ana Perez");
    expect(rows[0].textContent).toContain(en.ServiceNames.zelle);
    expect(rows[0].textContent?.replace(/ /g, " ")).toContain("GYD 30 000");
    expect(rows[0].textContent).toContain("2 d");
    expect(rows[1].textContent).toContain("Beto");
    expect(rows[1].textContent).toContain("1 d");
  });

  it("shows at most five rows", async () => {
    const ops = Array.from({ length: 7 }, (_, i) => op({ operationId: `o${i}`, stateSince: hoursAgo(30 + i) }));
    const node = await render(ops);
    expect(node.querySelectorAll("li").length).toBe(5);
  });

  it("opens the chat through the inbox target", async () => {
    const node = await render([op({ conversationId: "conv-9" })]);
    const link = node.querySelector("a")!;
    expect(link.getAttribute("href")).toBe("/inbox");
    expect(link.textContent).toBe(t.late.openChat);
    await act(async () => link.click());
    expect(setInboxOpenTarget).toHaveBeenCalledWith("conv-9");
  });
});
