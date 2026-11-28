// @vitest-environment jsdom
// The Cierres tab hands its active flag to the closed-weeks overview, which holds the financial close at its end.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("./cierres-overview", () => ({ CierresOverview: ({ active }: { active?: boolean }) => <div data-testid="overview" data-active={String(active)} /> }));

import { CierresTab } from "./cierres-tab";

afterEach(() => document.body.replaceChildren());

describe("CierresTab", () => {
  it("renders the closed-weeks overview", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    await act(async () => createRoot(node).render(<CierresTab active />));
    expect(node.querySelector("[data-testid=overview]")).not.toBeNull();
  });

  it("passes its active flag so the weeks are read again when the tab comes back", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<CierresTab active={false} />));
    expect(node.querySelector("[data-testid=overview]")!.getAttribute("data-active")).toBe("false");
    await act(async () => root.render(<CierresTab active />));
    expect(node.querySelector("[data-testid=overview]")!.getAttribute("data-active")).toBe("true");
  });
});
