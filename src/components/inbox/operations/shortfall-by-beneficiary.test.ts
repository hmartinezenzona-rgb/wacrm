import { describe, expect, it } from "vitest";
import type { OperationReceiptsRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { shortfallByBeneficiary } from "./remittance-operation-card";

function operation(amounts: Array<{ id: string; amount: number | null }>): RemittanceOperationRead {
  return { beneficiaries: amounts.map((b) => ({ id: b.id, amount: b.amount, beneficiaryType: "zelle" })) } as unknown as RemittanceOperationRead;
}

function receipts(objetivo: number, depositado: number): OperationReceiptsRead {
  return { objetivo, depositado, saldo: objetivo - depositado, moneda: "GYD" } as unknown as OperationReceiptsRead;
}

describe("shortfallByBeneficiary", () => {
  it("puts the missing GYD on the recipient the deposit cannot cover", () => {
    // 50 + 60 = 110 USD -> 28,600 GYD; 26,000 verified covers the first 50 and
    // 50 of the second, so the second still needs 2,600 GYD.
    const map = shortfallByBeneficiary(
      operation([
        { id: "a", amount: 50 },
        { id: "b", amount: 60 },
      ]),
      receipts(28600, 26000),
    );
    expect(map.get("a")).toBeUndefined();
    expect(map.get("b")).toEqual({ amount: 2600, currency: "GYD" });
  });

  it("carries nothing when the deposit covers every recipient", () => {
    const map = shortfallByBeneficiary(
      operation([
        { id: "a", amount: 50 },
        { id: "b", amount: 50 },
      ]),
      receipts(26000, 26000),
    );
    expect(map.size).toBe(0);
  });

  it("marks every recipient it cannot reach once the money runs out", () => {
    const map = shortfallByBeneficiary(
      operation([
        { id: "a", amount: 50 },
        { id: "b", amount: 60 },
        { id: "c", amount: 40 },
      ]),
      receipts(39000, 26000),
    );
    expect(map.get("a")).toBeUndefined();
    expect(map.get("b")).toEqual({ amount: 2600, currency: "GYD" });
    expect(map.get("c")).toEqual({ amount: 10400, currency: "GYD" });
  });

  it("does nothing without receipts, objective or amounts", () => {
    expect(shortfallByBeneficiary(operation([{ id: "a", amount: 50 }]), undefined).size).toBe(0);
    expect(shortfallByBeneficiary(operation([{ id: "a", amount: null }]), receipts(26000, 0)).size).toBe(0);
  });
});
