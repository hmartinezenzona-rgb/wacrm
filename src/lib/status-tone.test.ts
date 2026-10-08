import { describe, expect, it } from "vitest";
import { OPERATION_STATUSES, statusPillClass, statusTone, type StatusTone } from "./status-tone";

describe("statusTone", () => {
  const expected: Record<string, StatusTone> = {
    collecting_information: "neutral",
    awaiting_deposit: "info",
    deposit_received: "attention",
    deposit_verification: "attention",
    ready_to_transfer: "attention",
    transferring: "info",
    incident: "danger",
    completed: "success",
    awaiting_beneficiary: "info",
  };

  it.each(Object.entries(expected))("maps %s to %s", (status, tone) => {
    expect(statusTone(status)).toBe(tone);
  });

  it("covers every known operation status and nothing else", () => {
    expect([...OPERATION_STATUSES].sort()).toEqual(Object.keys(expected).sort());
  });

  it("falls back to neutral for an unknown, empty or missing status", () => {
    expect(statusTone("something_new")).toBe("neutral");
    expect(statusTone("")).toBe("neutral");
    expect(statusTone(null)).toBe("neutral");
    expect(statusTone(undefined)).toBe("neutral");
  });

  it("has a literal class for every tone", () => {
    expect(statusPillClass.info).toBe("bg-status-info-soft text-status-info");
    expect(statusPillClass.attention).toBe("bg-status-attention-soft text-status-attention");
    expect(statusPillClass.success).toBe("bg-status-success-soft text-status-success");
    expect(statusPillClass.danger).toBe("bg-status-danger-soft text-status-danger");
    expect(statusPillClass.neutral).toBe("bg-muted text-muted-foreground");
  });
});
