import { describe, expect, it } from "vitest";
import {
  BOARD_COLUMNS,
  AGE_ATTENTION_HOURS,
  AGE_DANGER_HOURS,
  ageParts,
  ageTone,
  chatHref,
  groupBoard,
  SERVICE_FILTERS,
  showMissingBeneficiaries,
  type BoardOperation,
} from "./board";

function op(over: Partial<BoardOperation> = {}): BoardOperation {
  return {
    operationId: "op-1",
    conversationId: "conv-1",
    contactName: "Ana",
    contactPhone: "5920000000",
    serviceType: "remesa",
    deliveryMethod: "zelle",
    status: "collecting_information",
    quotedSourceAmount: 30000,
    sourceCurrency: "GYD",
    createdAt: "2026-10-05T10:00:00Z",
    completedAt: null,
    stateSince: "2026-10-05T10:00:00Z",
    beneficiariesComplete: true,
    ...over,
  };
}

describe("groupBoard", () => {
  it("orders the columns requested, deposit check, ready to transfer, completed, incident (last)", () => {
    expect(BOARD_COLUMNS.map((c) => c.id)).toEqual(["requested", "depositCheck", "readyToTransfer", "completed", "incident"]);
  });

  it("puts each status in its column, merging ready_to_transfer and transferring, with counts", () => {
    const ops = [
      op({ operationId: "a", status: "collecting_information" }),
      op({ operationId: "b", status: "deposit_verification" }),
      op({ operationId: "c", status: "ready_to_transfer" }),
      op({ operationId: "d", status: "transferring" }),
      op({ operationId: "e", status: "incident" }),
      op({ operationId: "f", status: "completed", completedAt: "2026-10-05T11:00:00Z" }),
    ];
    const cols = groupBoard(ops, "all");
    expect(cols.map((c) => [c.id, c.count])).toEqual([
      ["requested", 1], ["depositCheck", 1], ["readyToTransfer", 2], ["completed", 1], ["incident", 1],
    ]);
    expect(cols[2].items.map((i) => i.operationId)).toEqual(["c", "d"]);
  });

  it("keeps completed operations out of the open columns", () => {
    const cols = groupBoard([op({ status: "completed" })], "all");
    expect(cols.find((c) => c.id === "completed")!.count).toBe(1);
    expect(cols.filter((c) => c.id !== "completed").every((c) => c.count === 0)).toBe(true);
  });

  it("filters a mobile balance by its own service", () => {
    const ops = [op({ operationId: "r" }), op({ operationId: "s", serviceType: "saldo" })];
    expect(SERVICE_FILTERS).toContain("saldo");
    expect(groupBoard(ops, "saldo").flatMap((c) => c.items.map((i) => i.operationId))).toEqual(["s"]);
  });

  it("shows awaiting_deposit under requested and deposit_received under deposit check, so neither vanishes", () => {
    const cols = groupBoard(
      [op({ operationId: "a", status: "awaiting_deposit" }), op({ operationId: "d", status: "deposit_received" })],
      "all",
    );
    expect(cols.find((c) => c.id === "requested")!.items.map((i) => i.operationId)).toEqual(["a"]);
    expect(cols.find((c) => c.id === "depositCheck")!.items.map((i) => i.operationId)).toEqual(["d"]);
  });

  it("ignores statuses the board does not show", () => {
    const cols = groupBoard([op({ status: "cancelled" })], "all");
    expect(cols.every((c) => c.count === 0)).toBe(true);
  });

  it("filters by service and recounts", () => {
    const ops = [op({ operationId: "r" }), op({ operationId: "c", serviceType: "combo" }), op({ operationId: "v", serviceType: "visa" })];
    expect(groupBoard(ops, "combo")[0].items.map((i) => i.operationId)).toEqual(["c"]);
    expect(groupBoard(ops, "combo")[0].count).toBe(1);
    expect(groupBoard(ops, "all")[0].count).toBe(3);
  });
});

describe("showMissingBeneficiaries", () => {
  it("flags an open operation with incomplete recipients", () => {
    expect(showMissingBeneficiaries(op({ beneficiariesComplete: false }))).toBe(true);
    expect(showMissingBeneficiaries(op({ serviceType: "recarga", beneficiariesComplete: false }))).toBe(true);
    expect(showMissingBeneficiaries(op({ serviceType: "combo", beneficiariesComplete: false }))).toBe(true);
  });
  it("never flags a complete one, a visa, or a completed operation", () => {
    expect(showMissingBeneficiaries(op({ beneficiariesComplete: true }))).toBe(false);
    expect(showMissingBeneficiaries(op({ serviceType: "visa", beneficiariesComplete: false }))).toBe(false);
    expect(showMissingBeneficiaries(op({ status: "completed", beneficiariesComplete: false }))).toBe(false);
  });
});

describe("ageParts", () => {
  const now = new Date("2026-10-05T12:00:00Z");
  it("reports minutes, hours and days", () => {
    expect(ageParts("2026-10-05T11:59:40Z", now)).toEqual({ unit: "lessThanMinute", value: 0 });
    expect(ageParts("2026-10-05T11:15:00Z", now)).toEqual({ unit: "minutes", value: 45 });
    expect(ageParts("2026-10-05T10:00:00Z", now)).toEqual({ unit: "hours", value: 2 });
    expect(ageParts("2026-10-02T12:00:00Z", now)).toEqual({ unit: "days", value: 3 });
  });
  it("never goes negative on clock skew", () => {
    expect(ageParts("2026-10-05T12:00:30Z", now)).toEqual({ unit: "lessThanMinute", value: 0 });
  });
});

describe("chatHref", () => {
  it("points at the inbox; the id travels in sessionStorage, not the URL", () => {
    expect(chatHref("abc")).toBe("/inbox");
  });
});

describe("ageTone", () => {
  const now = new Date("2026-10-05T12:00:00Z");
  const ago = (hours: number, minutes = 0) => new Date(now.getTime() - (hours * 60 + minutes) * 60_000).toISOString();

  it("names its thresholds: attention from 2 hours, danger from 24 hours", () => {
    expect(AGE_ATTENTION_HOURS).toBe(2);
    expect(AGE_DANGER_HOURS).toBe(24);
  });

  it("is muted while recent (1 h 59 min)", () => {
    expect(ageTone(ago(1, 59), now, "collecting_information")).toBe("muted");
  });

  it("turns to attention at exactly 2 h", () => {
    expect(ageTone(ago(2), now, "collecting_information")).toBe("attention");
  });

  it("stays attention at 23 h 59 min", () => {
    expect(ageTone(ago(23, 59), now, "ready_to_transfer")).toBe("attention");
  });

  it("turns to danger at exactly 24 h", () => {
    expect(ageTone(ago(24), now, "ready_to_transfer")).toBe("danger");
  });

  it("never escalates a completed operation", () => {
    expect(ageTone(ago(2), now, "completed")).toBe("muted");
    expect(ageTone(ago(30), now, "completed")).toBe("muted");
  });

  it("is muted on clock skew (a time in the future)", () => {
    expect(ageTone("2026-10-05T12:30:00Z", now, "incident")).toBe("muted");
  });
});
