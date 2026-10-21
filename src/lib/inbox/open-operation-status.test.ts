import { describe, expect, it } from "vitest";
import {
  openOperationStatusByConversation,
  pickOpenOperationStatus,
  type OpenOperationInput,
} from "./open-operation-status";

function op(overrides: Partial<OpenOperationInput> = {}): OpenOperationInput {
  return {
    conversationId: "c1",
    status: "awaiting_deposit",
    beneficiariesComplete: true,
    createdAt: "2026-10-21T10:00:00Z",
    ...overrides,
  };
}

describe("pickOpenOperationStatus", () => {
  it("returns null when there is no open operation", () => {
    expect(pickOpenOperationStatus([])).toBeNull();
    expect(pickOpenOperationStatus([op({ status: "completed" })])).toBeNull();
    expect(pickOpenOperationStatus([op({ status: "cancelled" })])).toBeNull();
    expect(pickOpenOperationStatus([op({ status: "something_new" })])).toBeNull();
  });

  it("uses the panel's effective status (same logic as the operations panel)", () => {
    expect(
      pickOpenOperationStatus([op({ status: "ready_to_transfer", beneficiariesComplete: false })]),
    ).toBe("awaiting_beneficiary");
    expect(
      pickOpenOperationStatus([op({ status: "collecting_information", beneficiariesComplete: true })]),
    ).toBe("awaiting_deposit");
    expect(pickOpenOperationStatus([op({ status: "transferring", beneficiariesComplete: null })])).toBe(
      "awaiting_beneficiary",
    );
  });

  it("picks the most urgent open operation", () => {
    const ops = [
      op({ status: "awaiting_deposit" }),
      op({ status: "ready_to_transfer" }),
      op({ status: "collecting_information", beneficiariesComplete: false }),
    ];
    expect(pickOpenOperationStatus(ops)).toBe("ready_to_transfer");
    expect(pickOpenOperationStatus([...ops, op({ status: "incident" })])).toBe("incident");
  });

  it("ranks the attention states by what the team must do next", () => {
    expect(
      pickOpenOperationStatus([op({ status: "deposit_received", beneficiariesComplete: false }), op({ status: "deposit_verification" })]),
    ).toBe("deposit_verification");
    expect(
      pickOpenOperationStatus([op({ status: "transferring" }), op({ status: "ready_to_transfer", beneficiariesComplete: false })]),
    ).toBe("awaiting_beneficiary");
  });

  it("breaks ties with the most recent operation", () => {
    const older = op({ status: "awaiting_deposit", createdAt: "2026-10-20T10:00:00Z" });
    const newer = op({ status: "awaiting_deposit", createdAt: "2026-10-21T10:00:00Z" });
    expect(pickOpenOperationStatus([older, newer])).toBe("awaiting_deposit");
  });

  it("ignores completed and cancelled operations next to an open one", () => {
    expect(
      pickOpenOperationStatus([op({ status: "completed" }), op({ status: "awaiting_deposit" })]),
    ).toBe("awaiting_deposit");
  });
});

describe("openOperationStatusByConversation", () => {
  it("groups by conversation and omits conversations without an open operation", () => {
    const map = openOperationStatusByConversation([
      op({ conversationId: "a", status: "incident" }),
      op({ conversationId: "a", status: "awaiting_deposit" }),
      op({ conversationId: "b", status: "completed" }),
      op({ conversationId: "c", status: "transferring" }),
    ]);
    expect(map.get("a")).toBe("incident");
    expect(map.has("b")).toBe(false);
    expect(map.get("c")).toBe("transferring");
    expect(map.size).toBe(2);
  });
});
