import { describe, expect, it } from "vitest";
import { PROGRESS_STEPS, progressStep } from "./progress-step";

describe("progressStep", () => {
  it("has four steps", () => {
    expect(PROGRESS_STEPS).toBe(4);
  });

  it.each([
    ["collecting_information", 1],
    ["awaiting_deposit", 2],
    ["deposit_received", 2],
    ["deposit_verification", 2],
    ["incident", 2],
    ["ready_to_transfer", 3],
    ["transferring", 3],
    ["awaiting_beneficiary", 3],
    ["completed", 4],
  ] as const)("maps %s to step %i", (status, step) => {
    expect(progressStep(status)).toBe(step);
  });
});
