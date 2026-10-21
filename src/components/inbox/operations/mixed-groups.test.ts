import { describe, expect, it } from "vitest";
import { groupOpenOperations, groupOperations, limitBlocks, mixedGroupMembers, mixedGroupTotal } from "./mixed-groups";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { formatNumber } from "@/lib/format-number";

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

describe("groupOperations over history", () => {
  it("gathers the completed members of a group at the place of its first member and keeps the others single", () => {
    const a = op("a", 18200, "g", "completed");
    const lone = op("l", 700, null, "completed");
    const b = op("b", 6200, "g", "completed");

    const blocks = groupOperations([a, lone, b], [a, lone, b]);

    expect(blocks.map((block) => block.operations.map((o) => o.id))).toEqual([["a", "b"], ["l"]]);
    expect(blocks[0]!.grouped).toBe(true);
    expect(blocks[0]!.members).toEqual([a, b]);
  });

  it("renders a group of one completed member as a plain block when its siblings are not in the list", () => {
    const done = op("a", 18200, "g", "completed");
    const open = op("b", 6200, "g");

    expect(groupOperations([done], [done])).toEqual([{ grouped: false, operations: [done], members: [done] }]);
    expect(groupOperations([done], [done, open])[0]!.members).toEqual([done, open]);
  });

  it("keeps groupOpenOperations as the same arrangement", () => {
    const a = op("a", 1, "g");
    const b = op("b", 2, "g");

    expect(groupOpenOperations([a, b], [a, b])).toEqual(groupOperations([a, b], [a, b]));
  });
});

describe("limitBlocks", () => {
  const single = (id: string) => ({ grouped: false, operations: [op(id, 1)], members: [op(id, 1)] });
  const group = (...ids: string[]) => {
    const members = ids.map((id) => op(id, 1, "g"));
    return { grouped: true, operations: members, members };
  };

  it("counts a group as one entry and never cuts it in half", () => {
    const blocks = [single("1"), group("2", "3"), single("4"), single("5")];

    const { visible, hiddenOperations } = limitBlocks(blocks, 2);

    expect(visible.map((block) => block.operations.map((o) => o.id))).toEqual([["1"], ["2", "3"]]);
    expect(hiddenOperations).toBe(2);
  });

  it("shows everything when the limit covers every block", () => {
    const blocks = [single("1"), group("2", "3")];

    expect(limitBlocks(blocks, 5)).toEqual({ visible: blocks, hiddenOperations: 0 });
  });
});

// ---- Trial (local model): the destination of each share ---------------------------------------------------------------
describe("mixedShareDestination", () => {
  function share(dest: number | null, currency: string | null): RemittanceOperationRead {
    return { id: "s", quotedSourceAmount: 18200, quotedDestinationAmount: dest, destinationCurrency: currency } as unknown as RemittanceOperationRead;
  }

  it("returns the destination amount and currency of a share", async () => {
    const { mixedShareDestination } = await import("./mixed-groups");
    expect(mixedShareDestination(share(70, "USD"))).toBe(`${formatNumber(70)} USD`);
    expect(mixedShareDestination(share(54600, "CUP"))).toBe(`${formatNumber(54600)} CUP`);
  });

  it("returns null when the share has no destination amount or currency, or the destination is GYD", async () => {
    const { mixedShareDestination } = await import("./mixed-groups");
    expect(mixedShareDestination(share(null, null))).toBeNull();
    expect(mixedShareDestination(share(70, null))).toBeNull();
    expect(mixedShareDestination(share(null, "USD"))).toBeNull();
    expect(mixedShareDestination(share(6200, "GYD"))).toBeNull();
  });
});
