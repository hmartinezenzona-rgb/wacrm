// The period summary and the history now live in Finanzas > Operaciones: /resumen only forwards old links and bookmarks.

import { describe, expect, it, vi } from "vitest";

const redirect = vi.hoisted(() => vi.fn());
vi.mock("next/navigation", () => ({ redirect }));

describe("/resumen", () => {
  it("redirects to the Operaciones tab of /finanzas on the server", async () => {
    const { default: ResumenPage } = await import("./page");
    ResumenPage();
    expect(redirect).toHaveBeenCalledWith("/finanzas?tab=operaciones");
  });
});
