// @vitest-environment jsdom
// The Cierres tab: the archived weeks, then the financial close below.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("./archived-weeks", () => ({ ArchivedWeeks: () => <div data-testid="weeks" /> }));
vi.mock("@/components/resumen/financial-close-section", () => ({ FinancialCloseSection: () => <section data-testid="close" /> }));

import { CierresTab } from "./cierres-tab";

afterEach(() => document.body.replaceChildren());

describe("CierresTab", () => {
  it("shows the archived weeks first and the financial close below", async () => {
    const node = document.createElement("div");
    document.body.appendChild(node);
    await act(async () => createRoot(node).render(<CierresTab />));
    const ids = [...node.querySelectorAll("[data-testid]")].map((el) => el.getAttribute("data-testid"));
    expect(ids).toEqual(["weeks", "close"]);
  });
});
