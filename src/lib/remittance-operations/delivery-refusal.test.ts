import { describe, expect, it } from "vitest";
import { parseDeliveryRefusal } from "./delivery-refusal";

describe("parseDeliveryRefusal", () => {
  it("maps the funding refusal with comma thousands", () => {
    expect(
      parseDeliveryRefusal(
        "the operation has 0 GYD of verified funding but needs 6200 GYD: verify the deposit before delivering",
      ),
    ).toEqual({ key: "fundingMissing", params: { deposited: "0", required: "6,200" } });
  });

  it("maps the simple refusals", () => {
    expect(parseDeliveryRefusal("operation is not ready to transfer")?.key).toBe("notReady");
    expect(parseDeliveryRefusal("beneficiary data is incomplete")?.key).toBe("beneficiariesIncomplete");
    expect(parseDeliveryRefusal("the operation has no source amount to fund")?.key).toBe("noSourceAmount");
  });

  it("maps the funding case conflict with its note", () => {
    expect(parseDeliveryRefusal("the funding case has a conflict: card prefix mismatch")).toEqual({
      key: "fundingConflict",
      params: { note: "card prefix mismatch" },
    });
  });

  it("maps the recipients sum mismatch, with and without currency", () => {
    expect(
      parseDeliveryRefusal(
        "the recipients add up to 9000 CUP but the operation sends 10000 CUP: complete them before delivering",
      ),
    ).toEqual({ key: "recipientsMismatch", params: { sum: "9,000", sent: "10,000", currency: "CUP" } });
    expect(
      parseDeliveryRefusal("the recipients add up to 9000  but the operation sends 10000.50 : complete them before delivering")
        ?.params,
    ).toEqual({ sum: "9,000", sent: "10,000.5", currency: "" });
  });

  it("maps the missing delivery proofs with the count", () => {
    expect(
      parseDeliveryRefusal("every beneficiary needs its delivery proof before delivering (2 missing)"),
    ).toEqual({ key: "proofsMissing", params: { count: 2 } });
  });

  it("returns null for an unknown message", () => {
    expect(parseDeliveryRefusal("something else")).toBeNull();
    expect(parseDeliveryRefusal("Network error")).toBeNull();
  });
});

describe("parseDeliveryRefusal: USD inventory block", () => {
  it("maps usd_inventory_insufficient with the service and the missing amount", () => {
    expect(parseDeliveryRefusal("usd_inventory_insufficient:TROPICAL:150 (needs 400 USD, 250 USD available)")).toEqual({
      key: "usdInventoryInsufficient",
      params: { service: "Tropical", missing: "150" },
    });
    expect(parseDeliveryRefusal("usd_inventory_insufficient:CLASICA:1234.5 (needs 2000 USD, 765.5 USD available)")).toEqual({
      key: "usdInventoryInsufficient",
      params: { service: "Clásica", missing: "1,234.5" },
    });
  });
});
