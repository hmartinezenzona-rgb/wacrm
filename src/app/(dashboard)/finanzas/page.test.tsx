// The server page turns ?tab= into the tab the view shows.

import { describe, expect, it, vi } from "vitest";

vi.mock("@/components/finanzas/finanzas-view", () => ({ FinanzasView: () => null }));

import FinanzasPage from "./page";

async function tabFor(searchParams: Record<string, string | string[] | undefined>) {
  const element = await FinanzasPage({ searchParams: Promise.resolve(searchParams) });
  return (element as { props: { tab: string } }).props.tab;
}

describe("/finanzas", () => {
  it.each(["semana", "cierres", "operaciones"])("opens the %s tab", async (tab) => {
    expect(await tabFor({ tab })).toBe(tab);
  });

  it("defaults to semana without ?tab and for unknown values", async () => {
    expect(await tabFor({})).toBe("semana");
    expect(await tabFor({ tab: "otra" })).toBe("semana");
    expect(await tabFor({ tab: ["cierres", "semana"] })).toBe("semana");
  });
});
