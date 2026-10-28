// @vitest-environment jsdom
// The Finanzas shell: an accessible tab list driven by ?tab=, one panel at a time, switching through the router.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const replace = vi.hoisted(() => vi.fn());
vi.mock("next/navigation", () => ({ useRouter: () => ({ replace }) }));
vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => (key: string) =>
    key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)?.[part], (es as unknown as Record<string, unknown>)[namespace]) as string,
}));
vi.mock("./semana-tab", () => ({ SemanaTab: () => <div data-testid="semana-content" /> }));
vi.mock("./cierres-tab", () => ({ CierresTab: () => <div data-testid="cierres-content" /> }));
vi.mock("./operaciones-tab", () => ({ OperacionesTab: () => <div data-testid="operaciones-content" /> }));

import { FinanzasView } from "./finanzas-view";
import type { FinanzasTab } from "@/lib/finanzas/tabs";

async function renderView(tab: FinanzasTab) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<FinanzasView tab={tab} />));
  return { node, root };
}

afterEach(() => {
  document.body.replaceChildren();
  replace.mockClear();
});

describe("FinanzasView", () => {
  it("renders the title and the three tabs in order with the Spanish labels", async () => {
    const { node, root } = await renderView("semana");
    expect(node.querySelector("h1")?.textContent).toBe("Finanzas");
    const tabs = [...node.querySelectorAll("[role=tab]")];
    expect(tabs.map((t) => t.textContent)).toEqual(["Semana", "Cierres", "Operaciones"]);
    expect(node.querySelectorAll("[role=tablist]")).toHaveLength(1);
    await act(async () => root.unmount());
  });

  it.each([
    ["semana", 0],
    ["cierres", 1],
    ["operaciones", 2],
  ] as const)("shows only the %s panel and marks its tab selected", async (tab, index) => {
    const { node, root } = await renderView(tab);
    const tabs = [...node.querySelectorAll("[role=tab]")];
    tabs.forEach((el, i) => expect(el.getAttribute("aria-selected")).toBe(String(i === index)));
    const panel = node.querySelector("[role=tabpanel]")!;
    expect(node.querySelectorAll("[role=tabpanel]")).toHaveLength(1);
    expect(panel.getAttribute("aria-labelledby")).toBe(tabs[index]!.id);
    expect(tabs[index]!.getAttribute("aria-controls")).toBe(panel.id);
    expect(panel.querySelector(`[data-testid=${tab}-content]`)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("switches tabs through the router without leaving the page, keeping the scroll", async () => {
    const { node, root } = await renderView("semana");
    await act(async () => { (node.querySelectorAll("[role=tab]")[1] as HTMLButtonElement).click(); });
    expect(replace).toHaveBeenCalledWith("/finanzas?tab=cierres", { scroll: false });
    await act(async () => root.unmount());
  });

  it("moves between tabs with the arrow keys", async () => {
    const { node, root } = await renderView("semana");
    const first = node.querySelectorAll("[role=tab]")[0] as HTMLButtonElement;
    await act(async () => { first.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })); });
    expect(replace).toHaveBeenCalledWith("/finanzas?tab=cierres", { scroll: false });
    await act(async () => root.unmount());
  });
});
