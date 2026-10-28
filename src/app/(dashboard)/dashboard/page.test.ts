// The Dashboard is gone: /dashboard only forwards old links and bookmarks to the Tablero.

import { describe, expect, it, vi } from "vitest";

const redirect = vi.hoisted(() => vi.fn());
vi.mock("next/navigation", () => ({ redirect }));

describe("/dashboard", () => {
  it("redirects to /tablero on the server", async () => {
    const { default: DashboardPage } = await import("./page");
    DashboardPage();
    expect(redirect).toHaveBeenCalledWith("/tablero");
  });
});
