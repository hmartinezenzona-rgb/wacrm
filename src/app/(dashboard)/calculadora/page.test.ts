// The weekly calculator now lives in Finanzas > Semana: /calculadora only forwards old links and bookmarks.

import { describe, expect, it, vi } from "vitest";

const redirect = vi.hoisted(() => vi.fn());
vi.mock("next/navigation", () => ({ redirect }));

describe("/calculadora", () => {
  it("redirects to the Semana tab of /finanzas on the server", async () => {
    const { default: CalculadoraPage } = await import("./page");
    CalculadoraPage();
    expect(redirect).toHaveBeenCalledWith("/finanzas?tab=semana");
  });
});
