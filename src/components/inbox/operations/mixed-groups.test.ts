import { describe, expect, it } from "vitest";
import { groupOpenOperations, mixedGroupMembers, mixedGroupTotal } from "./mixed-groups";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

function op(id: string, amount: number | null, mixedGroupId: string | null = null, status = "ready_to_transfer"): RemittanceOperationRead {
  return { id, quotedSourceAmount: amount, mixedGroupId, status } as unknown as RemittanceOperationRead;
}

describe("mixedGroupMembers", () => {
  it("returns the operation alone when it is not grouped", () => {
    const lone = op("a", 100);

    expect(mixedGroupMembers(lone, [lone, op("b", 200)])).toEqual([lone]);
  });

  it("returns every operation of the same group, history included, in the given order", () => {
    const a = op("a", 18200, "a");
    const b = op("b", 6200, "a");
    const done = op("c", 500, "a", "completed");
    const other = op("d", 900, "z");

    expect(mixedGroupMembers(b, [a, b, other, done])).toEqual([a, b, done]);
  });

  it("falls back to the operation alone when the group has no other visible member", () => {
    const a = op("a", 100, "a");

    expect(mixedGroupMembers(a, [a])).toEqual([a]);
  });
});

describe("mixedGroupTotal", () => {
  it("adds the quoted GYD of the members and counts a missing amount as zero", () => {
    expect(mixedGroupTotal([op("a", 18200), op("b", 6200), op("c", null)])).toBe(24400);
  });
});

describe("groupOpenOperations", () => {
  it("keeps ungrouped operations as single blocks and gathers a group at its first member", () => {
    const a = op("a", 18200, "a");
    const lone = op("l", 700);
    const b = op("b", 6200, "a");

    const blocks = groupOpenOperations([a, lone, b], [a, lone, b]);

    expect(blocks.map((block) => block.operations.map((o) => o.id))).toEqual([["a", "b"], ["l"]]);
    expect(blocks[0]!.grouped).toBe(true);
    expect(blocks[1]!.grouped).toBe(false);
  });

  it("does not show a group header when only one member is visible", () => {
    const a = op("a", 100, "a");

    expect(groupOpenOperations([a], [a])).toEqual([{ grouped: false, operations: [a], members: [a] }]);
  });

  it("lists a completed member in the group's members without rendering its card", () => {
    const a = op("a", 18200, "a");
    const done = op("c", 6200, "a", "completed");

    const [block] = groupOpenOperations([a], [a, done]);

    expect(block!.grouped).toBe(true);
    expect(block!.operations).toEqual([a]);
    expect(block!.members).toEqual([a, done]);
  });
});
