import { describe, it, expect } from "vitest";
import {
  DELIVERED_STAGE_ID,
  DELIVERY_PROOF_STAGE_ID,
  acceptsDeliveryProof,
  isDeliveredStage,
} from "./delivery-stages";

describe("which stages the feature attaches to", () => {
  it("offers the proof panel on 'Lista para transferir' only", () => {
    expect(acceptsDeliveryProof(DELIVERY_PROOF_STAGE_ID)).toBe(true);
    expect(acceptsDeliveryProof(DELIVERED_STAGE_ID)).toBe(false);
    // "Solicitada", from the audited remittance pipeline.
    expect(acceptsDeliveryProof("96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109")).toBe(
      false,
    );
  });

  // DP-19
  it("only treats 'Entregada' as the stage that sends the proof", () => {
    expect(isDeliveredStage(DELIVERED_STAGE_ID)).toBe(true);
    // "Incidencia" — a deal moved here must never send a proof.
    expect(isDeliveredStage("da7b3e24-9222-4150-8be8-d7f7378e16aa")).toBe(false);
    expect(isDeliveredStage(DELIVERY_PROOF_STAGE_ID)).toBe(false);
  });

  it("says no for a stage from any other pipeline", () => {
    // A seeded "Sales Pipeline" column, or any other account's board:
    // the feature must be invisible there.
    expect(acceptsDeliveryProof("00000000-0000-0000-0000-000000000000")).toBe(
      false,
    );
    expect(isDeliveredStage("00000000-0000-0000-0000-000000000000")).toBe(false);
  });

  it("says no for a missing stage id rather than throwing", () => {
    expect(acceptsDeliveryProof(null)).toBe(false);
    expect(acceptsDeliveryProof(undefined)).toBe(false);
    expect(acceptsDeliveryProof("")).toBe(false);
    expect(isDeliveredStage(null)).toBe(false);
    expect(isDeliveredStage("")).toBe(false);
  });

  it("keeps the two stages distinct", () => {
    // A misconfigured env that pointed both at the same column would
    // arm the send on the same stage that prepares it.
    expect(DELIVERY_PROOF_STAGE_ID).not.toBe(DELIVERED_STAGE_ID);
  });
});
