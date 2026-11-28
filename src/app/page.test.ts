import { describe, expect, it, vi } from "vitest";

const redirect = vi.hoisted(() => vi.fn());
vi.mock("next/navigation", () => ({ redirect }));

describe("root page", () => {
  it("lands on the Tablero", async () => {
    const { default: RootPage } = await import("./page");
    RootPage();
    expect(redirect).toHaveBeenCalledWith("/tablero");
  });
});
