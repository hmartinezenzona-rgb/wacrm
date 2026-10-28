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
const mounts = vi.hoisted(() => ({ semana: 0, cierres: 0, operaciones: 0 }));
const cierresActive = vi.hoisted(() => ({ values: [] as boolean[] }));
vi.mock("./semana-tab", () => ({
  SemanaTab: () => {
    React.useEffect(() => { mounts.semana += 1; }, []);
    return <div data-testid="semana-content"><input data-testid="draft" /></div>;
  },
}));
vi.mock("./cierres-tab", () => ({
  CierresTab: ({ active }: { active: boolean }) => {
    React.useEffect(() => { mounts.cierres += 1; }, []);
    cierresActive.values.push(active);
    return <div data-testid="cierres-content" />;
  },
}));
vi.mock("./operaciones-tab", () => ({
  OperacionesTab: () => {
    React.useEffect(() => { mounts.operaciones += 1; }, []);
    return <div data-testid="operaciones-content" />;
  },
}));

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
  Object.assign(mounts, { semana: 0, cierres: 0, operaciones: 0 });
  cierresActive.values.length = 0;
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
  ] as const)("opens on the %s tab: its tab is selected and only its panel is visible", async (tab, index) => {
    const { node, root } = await renderView(tab);
    const tabs = [...node.querySelectorAll("[role=tab]")];
    tabs.forEach((el, i) => expect(el.getAttribute("aria-selected")).toBe(String(i === index)));
    const panels = [...node.querySelectorAll("[role=tabpanel]")] as HTMLElement[];
    const visible = panels.filter((p) => !p.hidden);
    expect(visible).toHaveLength(1);
    expect(visible[0]!.getAttribute("aria-labelledby")).toBe(tabs[index]!.id);
    expect(tabs[index]!.getAttribute("aria-controls")).toBe(visible[0]!.id);
    expect(visible[0]!.querySelector(`[data-testid=${tab}-content]`)).not.toBeNull();
    // a tab nobody visited is not mounted
    expect(panels).toHaveLength(1);
    await act(async () => root.unmount());
  });

  // Osmany's draft: the Semana autosave waits 600 ms, so leaving the tab must not unmount it.
  it("keeps Semana mounted (same DOM node, same typed text) while visiting Cierres and coming back", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<FinanzasView tab="semana" />));
    const draft = node.querySelector("[data-testid=draft]") as HTMLInputElement;
    draft.value = "last keystrokes";

    await act(async () => root.render(<FinanzasView tab="cierres" />));
    const semanaPanel = node.querySelector("#finanzas-panel-semana") as HTMLElement;
    expect(semanaPanel.hidden).toBe(true);
    expect(node.querySelector("#finanzas-panel-cierres")!.hasAttribute("hidden")).toBe(false);

    await act(async () => root.render(<FinanzasView tab="semana" />));
    expect(node.querySelector("[data-testid=draft]")).toBe(draft);
    expect(draft.value).toBe("last keystrokes");
    expect(mounts.semana).toBe(1);
    expect((node.querySelector("#finanzas-panel-semana") as HTMLElement).hidden).toBe(false);
    expect((node.querySelector("#finanzas-panel-cierres") as HTMLElement).hidden).toBe(true);
    await act(async () => root.unmount());
  });

  it("mounts a tab on its first visit only and tells Cierres whether it is the active tab", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<FinanzasView tab="semana" />));
    expect(mounts).toEqual({ semana: 1, cierres: 0, operaciones: 0 });

    await act(async () => root.render(<FinanzasView tab="cierres" />));
    await act(async () => root.render(<FinanzasView tab="operaciones" />));
    await act(async () => root.render(<FinanzasView tab="cierres" />));
    expect(mounts).toEqual({ semana: 1, cierres: 1, operaciones: 1 });
    expect(cierresActive.values.at(-1)).toBe(true);
    await act(async () => root.render(<FinanzasView tab="semana" />));
    expect(cierresActive.values.at(-1)).toBe(false);
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
