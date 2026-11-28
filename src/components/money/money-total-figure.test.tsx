// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { formatNumber } from "@/lib/format-number";
import { MoneyTotalFigure } from "./money-total-figure";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const fmt = (n: number) => formatNumber(n, { minimumFractionDigits: 2, maximumFractionDigits: 2 });

async function render(kind: "in" | "out" | "result", value: number) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<MoneyTotalFigure kind={kind} value={value} format={fmt} />));
  return node.firstElementChild as HTMLElement;
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("MoneyTotalFigure", () => {
  it("shows a positive result with + in the profit tone and an icon", async () => {
    const el = await render("result", 4000);
    expect(el.textContent).toBe("+4 000,00");
    expect(el.dataset.tone).toBe("profit");
    expect(el.className).toContain("text-money-profit");
    expect(el.querySelector("svg")).not.toBeNull();
  });

  it("shows a negative result with the true minus sign in the loss tone", async () => {
    const el = await render("result", -1250.5);
    expect(el.textContent).toBe("−1 250,50");
    expect(el.dataset.tone).toBe("loss");
    expect(el.className).toContain("text-money-loss");
  });

  it("shows a zero result unsigned and neutral", async () => {
    const el = await render("result", 0);
    expect(el.textContent).toBe("0,00");
    expect(el.dataset.tone).toBe("neutral");
    expect(el.className).not.toContain("text-money-");
  });

  it("colours facturado blue and invertido amber, without a sign", async () => {
    const inEl = await render("in", 30000);
    expect(inEl.textContent).toBe("30 000,00");
    expect(inEl.dataset.tone).toBe("in");
    const outEl = await render("out", 24000);
    expect(outEl.textContent).toBe("24 000,00");
    expect(outEl.dataset.tone).toBe("out");
  });
});
