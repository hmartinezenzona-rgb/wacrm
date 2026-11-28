import { describe, expect, it } from "vitest";
import { patchById } from "./patch-by-id";

interface Row {
  id: string;
  text: string;
  count: number;
}

const list: Row[] = [
  { id: "a", text: "one", count: 1 },
  { id: "b", text: "two", count: 2 },
  { id: "c", text: "three", count: 3 },
];

describe("patchById", () => {
  it("returns the same array reference when the id is absent", () => {
    const result = patchById(list, "missing", { text: "changed" });
    expect(result).toBe(list);
  });

  it("returns the same array reference when every patched field is already equal", () => {
    const result = patchById(list, "b", { text: "two", count: 2 });
    expect(result).toBe(list);
  });

  it("replaces only the matching element and keeps the other identities", () => {
    const result = patchById(list, "b", { text: "updated" });

    expect(result).not.toBe(list);
    expect(result).toHaveLength(list.length);
    expect(result[0]).toBe(list[0]);
    expect(result[2]).toBe(list[2]);
    expect(result[1]).toEqual({ id: "b", text: "updated", count: 2 });
  });

  it("does not mutate the input list", () => {
    const original = { ...list[1] };
    patchById(list, "b", { text: "updated" });
    expect(list[1]).toEqual(original);
  });

  it("treats an undefined patch as equal to a missing field", () => {
    const sparse = [{ id: "a" }, { id: "b" }] as { id: string; note?: string }[];
    const result = patchById(sparse, "a", { note: undefined });
    expect(result).toBe(sparse);
  });
});
