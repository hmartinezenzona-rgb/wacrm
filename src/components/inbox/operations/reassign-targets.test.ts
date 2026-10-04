import { describe, expect, it } from "vitest";
import { otherOpenOperationsFor } from "./reassign-targets";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

function op(id: string, serviceType: string, status = "collecting_information"): RemittanceOperationRead {
  return {
    id,
    serviceType,
    status,
    quotedSourceAmount: 1000,
    sourceCurrency: serviceType === "combo" ? "GYD" : "USD",
    destinationCurrency: serviceType === "combo" ? null : "CUP",
  } as unknown as RemittanceOperationRead;
}

describe("otherOpenOperationsFor", () => {
  const ops = [op("r1", "remesa"), op("r2", "remesa"), op("c1", "combo"), op("c2", "combo"), op("c3", "combo", "completed")];

  it("offers a remesa operation the other open non-combo operations only", () => {
    expect(otherOpenOperationsFor(ops[0]!, ops).map((t) => t.id)).toEqual(["r2"]);
  });

  it("offers a combo operation the other open combo operations only", () => {
    expect(otherOpenOperationsFor(ops[2]!, ops).map((t) => t.id)).toEqual(["c2"]);
  });

  it("labels a combo target without a destination arrow", () => {
    expect(otherOpenOperationsFor(ops[2]!, ops)[0]!.label).toBe("1000 GYD");
  });

  it("keeps the remesa label unchanged", () => {
    expect(otherOpenOperationsFor(ops[0]!, ops)[0]!.label).toBe("1000 USD → CUP");
  });
});
