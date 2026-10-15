import { describe, expect, it } from "vitest";
import { formatCup, formatRate, moveCardPriorities, parseCupNumber } from "./format";

describe("formatCup", () => {
  it("groups in threes with a narrow blank and drops empty decimals", () => {
    expect(formatCup(500000)).toBe("500\u202f000");
    expect(formatCup(0)).toBe("0");
    expect(formatCup(1157712.4)).toBe("1\u202f157\u202f712,4");
  });
});

describe("formatRate", () => {
  it("shows up to two decimals", () => {
    expect(formatRate(960)).toBe("960");
    expect(formatRate(1060.5)).toBe("1\u202f060,5");
    expect(formatRate(1060.456)).toBe("1\u202f060,46");
  });
});

describe("parseCupNumber", () => {
  it.each([
    ["500000", 500000],
    ["500 000", 500000],
    ["500 000", 500000],
    ["500.000", 500000],
    ["1.157.712,40", 1157712.4],
    ["1,157,712.40", 1157712.4],
    ["960", 960],
    ["960,5", 960.5],
    ["960.5", 960.5],
    ["  1060 ", 1060],
  ])("parses %j as %d", (text, expected) => {
    expect(parseCupNumber(text)).toBeCloseTo(expected, 6);
  });

  it.each(["", "   ", "abc", "12a", "-5", "0", "1e3", "1,2,3", "Infinity"])("rejects %j", (text) => {
    expect(parseCupNumber(text)).toBeNull();
  });
});

describe("moveCardPriorities", () => {
  const cards = [
    { id: "a", priority: 1 },
    { id: "b", priority: 2 },
    { id: "c", priority: 3 },
  ];

  it("moving a card up swaps it with the previous one and renumbers 1..n", () => {
    expect(moveCardPriorities(cards, "b", "up")).toEqual([
      { id: "b", priority: 1 },
      { id: "a", priority: 2 },
    ]);
  });

  it("moving a card down swaps it with the next one", () => {
    expect(moveCardPriorities(cards, "b", "down")).toEqual([
      { id: "c", priority: 2 },
      { id: "b", priority: 3 },
    ]);
  });

  it("moving the first up or the last down changes nothing", () => {
    expect(moveCardPriorities(cards, "a", "up")).toEqual([]);
    expect(moveCardPriorities(cards, "c", "down")).toEqual([]);
  });

  it("an unknown card changes nothing", () => {
    expect(moveCardPriorities(cards, "zzz", "up")).toEqual([]);
  });

  it("repairs ties and gaps while moving, patching only what changes", () => {
    const tied = [
      { id: "a", priority: 5 },
      { id: "b", priority: 5 },
      { id: "c", priority: 9 },
    ];
    expect(moveCardPriorities(tied, "c", "up")).toEqual([
      { id: "a", priority: 1 },
      { id: "c", priority: 2 },
      { id: "b", priority: 3 },
    ]);
  });
});
