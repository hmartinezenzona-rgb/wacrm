// Unit tests for `effectiveStatus` — the panel's readiness projection over
// `RemittanceOperationRead` (migration 102: `is_history` +
// `beneficiaries_complete`). Spec: panel-26 "effective status".

import { describe, expect, it } from "vitest";
import { effectiveStatus } from "./effective-status";
import type { RemittanceOperationStatus } from "./types";

function op(overrides: {
  status: RemittanceOperationStatus;
  isHistory?: boolean;
  beneficiariesComplete?: boolean;
}) {
  return {
    status: overrides.status,
    isHistory: overrides.isHistory ?? false,
    beneficiariesComplete: overrides.beneficiariesComplete ?? false,
  };
}

describe("effectiveStatus", () => {
  it("is completed for a history operation regardless of its raw status", () => {
    expect(effectiveStatus(op({ status: "ready_to_transfer", isHistory: true }))).toBe("completed");
    expect(effectiveStatus(op({ status: "collecting_information", isHistory: true }))).toBe("completed");
  });

  it("is completed for status completed", () => {
    expect(effectiveStatus(op({ status: "completed" }))).toBe("completed");
  });

  it("leaves incident unchanged regardless of beneficiariesComplete", () => {
    expect(effectiveStatus(op({ status: "incident", beneficiariesComplete: true }))).toBe("incident");
    expect(effectiveStatus(op({ status: "incident", beneficiariesComplete: false }))).toBe("incident");
  });

  it("leaves deposit_verification unchanged regardless of beneficiariesComplete", () => {
    expect(effectiveStatus(op({ status: "deposit_verification", beneficiariesComplete: true }))).toBe(
      "deposit_verification",
    );
    expect(effectiveStatus(op({ status: "deposit_verification", beneficiariesComplete: false }))).toBe(
      "deposit_verification",
    );
  });

  it("keeps ready_to_transfer when beneficiaries are complete", () => {
    expect(effectiveStatus(op({ status: "ready_to_transfer", beneficiariesComplete: true }))).toBe(
      "ready_to_transfer",
    );
  });

  it("demotes ready_to_transfer to awaiting_beneficiary when beneficiaries are incomplete", () => {
    expect(effectiveStatus(op({ status: "ready_to_transfer", beneficiariesComplete: false }))).toBe(
      "awaiting_beneficiary",
    );
  });

  it("keeps transferring when beneficiaries are complete", () => {
    expect(effectiveStatus(op({ status: "transferring", beneficiariesComplete: true }))).toBe("transferring");
  });

  it("demotes transferring to awaiting_beneficiary when beneficiaries are incomplete", () => {
    expect(effectiveStatus(op({ status: "transferring", beneficiariesComplete: false }))).toBe(
      "awaiting_beneficiary",
    );
  });

  it("promotes collecting_information to awaiting_deposit when beneficiaries are complete", () => {
    expect(effectiveStatus(op({ status: "collecting_information", beneficiariesComplete: true }))).toBe(
      "awaiting_deposit",
    );
  });

  it("leaves collecting_information unchanged when beneficiaries are incomplete", () => {
    expect(effectiveStatus(op({ status: "collecting_information", beneficiariesComplete: false }))).toBe(
      "collecting_information",
    );
  });

  it("promotes deposit_received to awaiting_deposit when beneficiaries are complete", () => {
    expect(effectiveStatus(op({ status: "deposit_received", beneficiariesComplete: true }))).toBe(
      "awaiting_deposit",
    );
  });

  it("leaves deposit_received unchanged when beneficiaries are incomplete", () => {
    expect(effectiveStatus(op({ status: "deposit_received", beneficiariesComplete: false }))).toBe(
      "deposit_received",
    );
  });

  it("leaves awaiting_deposit unchanged either way", () => {
    expect(effectiveStatus(op({ status: "awaiting_deposit", beneficiariesComplete: true }))).toBe(
      "awaiting_deposit",
    );
    expect(effectiveStatus(op({ status: "awaiting_deposit", beneficiariesComplete: false }))).toBe(
      "awaiting_deposit",
    );
  });
});
