// @vitest-environment jsdom
// The Cierres tab: the archived weeks, then the financial close below.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("./archived-weeks", () => ({ ArchivedWeeks: ({ active }: { active?: boolean }) => <div data-testid="weeks" data-active={String(active)} /> }));
vi.mock("@/components/resumen/financial-close-section", () => ({ FinancialCloseSection: () => <section data-testid="close" /> }));

import { CierresTab } from "./cierres-tab";

afterEach(() => document.body.replaceChildren());

describe("CierresTab", () => {
  it("shows the archived weeks first and the financial close below", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    await act(async () => createRoot(node).render(<CierresTab active />));
    const ids = [...node.querySelectorAll("[data-testid]")].map((el) => el.getAttribute("data-testid"));
    expect(ids).toEqual(["weeks", "close"]);
  });

  it("passes its active flag to the archived weeks so they refetch when the tab comes back", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<CierresTab active={false} />));
    expect(node.querySelector("[data-testid=weeks]")!.getAttribute("data-active")).toBe("false");
    await act(async () => root.render(<CierresTab active />));
    expect(node.querySelector("[data-testid=weeks]")!.getAttribute("data-active")).toBe("true");
  });
});
