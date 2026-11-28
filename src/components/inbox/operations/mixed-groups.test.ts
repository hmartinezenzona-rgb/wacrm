import { describe, expect, it } from "vitest";
import { completableGroup, groupOpenOperations, groupOperations, isPlannedGroupId, limitBlocks, mixedGroupMembers, mixedGroupTotal, withPlannedSplit } from "./mixed-groups";
import type { OperationReceiptsRead, PlannedSplitRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
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

describe("completableGroup", () => {
  const deposit = (transId: string, amount = 31000) => ({ transId, amount, currency: "GYD", receivedAt: null, consumedAt: null });
  const receipts = (...consumed: Array<ReturnType<typeof deposit>[]>) =>
    Object.fromEntries(
      consumed.map((list, index) => [
        `m${index + 1}`,
        { operationId: `m${index + 1}`, consumedDeposits: list } as unknown as OperationReceiptsRead,
      ]),
    );
  const ready = (id: string, extra: Record<string, unknown> = {}) =>
    ({ ...op(id, 1000, "m1"), isHistory: false, beneficiariesComplete: true, ...extra }) as unknown as RemittanceOperationRead;

  it("is the group's one consumed deposit when every member is ready and only one deposit pays them", () => {
    const members = [ready("m1"), ready("m2")];

    // The deposit sits on the anchor's deal; the other member has none of its own.
    expect(completableGroup(members, receipts([deposit("T1")], []))?.deposit.transId).toBe("T1");
    // The same deposit listed on both members is still one deposit.
    expect(completableGroup(members, receipts([deposit("T1")], [deposit("T1")]))?.deposit.transId).toBe("T1");
  });

  it("is null with two different deposits or with none", () => {
    const members = [ready("m1"), ready("m2")];

    expect(completableGroup(members, receipts([deposit("T1")], [deposit("T2")]))).toBeNull();
    expect(completableGroup(members, receipts([], []))).toBeNull();
  });

  it("is null when a member is not ready, is history, or its receipts are unknown", () => {
    const one = receipts([deposit("T1")], []);

    expect(completableGroup([ready("m1"), ready("m2", { status: "deposit_verification" })], one)).toBeNull();
    expect(completableGroup([ready("m1"), ready("m2", { beneficiariesComplete: false })], one)).toBeNull();
    expect(completableGroup([ready("m1"), ready("m2", { isHistory: true, status: "completed" })], one)).toBeNull();
    expect(completableGroup([ready("m1"), ready("m2")], { m1: one.m1! })).toBeNull();
    expect(completableGroup([ready("m1"), ready("m2")], undefined)).toBeNull();
  });

  it("is null for a single operation", () => {
    expect(completableGroup([ready("m1")], receipts([deposit("T1")]))).toBeNull();
  });
});

// ---- A split planned before the deposit shows as one mixed send waiting for it (migrations 369, 370) -----------------------
describe("withPlannedSplit", () => {
  const plan: PlannedSplitRead = {
    totalGyd: 25400,
    parts: [
      { service: "recarga", amountGyd: 12400 },
      { service: "zelle", amountGyd: 13000 },
    ],
  };
  function planned(id: string, serviceType: string, deliveryMethod: string | null, amount: number | null, status = "collecting_information", extra: Partial<RemittanceOperationRead> = {}) {
    return { id, serviceType, deliveryMethod, quotedSourceAmount: amount, mixedGroupId: null, status, isHistory: false, beneficiaries: [], ...extra } as unknown as RemittanceOperationRead;
  }

  it("puts the operations of the plan's parts in one planned group, so they render as one mixed send with the plan's total", () => {
    const recarga = planned("r", "recarga", null, 12400);
    const zelle = planned("z", "remesa", "zelle", 13000);

    const result = withPlannedSplit([zelle, recarga], plan, "conv-1");
    const blocks = groupOperations(result, result);

    expect(blocks).toHaveLength(1);
    expect(blocks[0]!.grouped).toBe(true);
    expect(isPlannedGroupId(blocks[0]!.members[0]!.mixedGroupId)).toBe(true);
    expect(mixedGroupTotal(blocks[0]!.members)).toBe(25400);
  });

  it("shows the plan's amount for a part whose operation still has none (a plan made before 369)", () => {
    const result = withPlannedSplit([planned("z", "remesa", "zelle", 0), planned("r", "recarga", null, 12400)], plan, "conv-1");

    expect(mixedGroupTotal(result)).toBe(25400);
  });

  it("changes nothing without a plan, with one matching part, or when an operation is already grouped, funded or closed", () => {
    const recarga = planned("r", "recarga", null, 12400);
    const zelle = planned("z", "remesa", "zelle", 13000);

    expect(withPlannedSplit([recarga, zelle], null, "conv-1")).toEqual([recarga, zelle]);
    expect(withPlannedSplit([recarga], plan, "conv-1")).toEqual([recarga]);
    const grouped = planned("z", "remesa", "zelle", 13000, "collecting_information", { mixedGroupId: "g" });
    expect(withPlannedSplit([recarga, grouped], plan, "conv-1")).toEqual([recarga, grouped]);
    const funded = planned("z", "remesa", "zelle", 13000, "deposit_verification");
    expect(withPlannedSplit([recarga, funded], plan, "conv-1")).toEqual([recarga, funded]);
    const history = planned("z", "remesa", "zelle", 13000, "completed", { isHistory: true });
    expect(withPlannedSplit([recarga, history], plan, "conv-1")).toEqual([recarga, history]);
  });

  it("leaves an operation of a service outside the plan alone", () => {
    const other = planned("o", "remesa", "clasica", 5000);
    const result = withPlannedSplit([planned("r", "recarga", null, 12400), planned("z", "remesa", "zelle", 13000), other], plan, "conv-1");

    expect(result.find((operation) => operation.id === "o")!.mixedGroupId).toBeNull();
  });
});
