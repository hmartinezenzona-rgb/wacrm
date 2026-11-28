import { describe, expect, it, vi } from "vitest";
import { fetchAllInBatches } from "./export-contacts";

describe("fetchAllInBatches", () => {
  it("pages until a short batch is returned", async () => {
    const data = Array.from({ length: 2500 }, (_, i) => i);
    const fetchPage = vi.fn(async (offset: number, limit: number) => ({
      rows: data.slice(offset, offset + limit),
    }));
    const all = await fetchAllInBatches(fetchPage, 1000);
    expect(all).toHaveLength(2500);
    expect(fetchPage.mock.calls.map((c) => c[0])).toEqual([0, 1000, 2000]);
  });

  it("makes one extra empty call when the total is an exact multiple", async () => {
    const data = Array.from({ length: 2000 }, (_, i) => i);
    const fetchPage = vi.fn(async (offset: number, limit: number) => ({
      rows: data.slice(offset, offset + limit),
    }));
    expect(await fetchAllInBatches(fetchPage, 1000)).toHaveLength(2000);
    expect(fetchPage).toHaveBeenCalledTimes(3);
  });

  it("propagates errors", async () => {
    await expect(
      fetchAllInBatches(async () => {
        throw new Error("boom");
      }, 1000),
    ).rejects.toThrow("boom");
  });
});
