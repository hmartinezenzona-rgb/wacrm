import { describe, expect, it } from "vitest";
import {
  OPERATION_SERVICES,
  SALDO_PRICE_GYD,
  SALDO_UNIT_CUP,
  currentServiceOf,
  isOperationService,
  saldoPackages,
} from "./services";

describe("OPERATION_SERVICES", () => {
  it("includes the mobile balance (migration 223) and validates it", () => {
    expect(OPERATION_SERVICES).toContain("saldo");
    expect(isOperationService("saldo")).toBe(true);
    expect(isOperationService("bitcoin")).toBe(false);
  });
});

describe("currentServiceOf", () => {
  const op = (serviceType: string, deliveryMethod: string | null = null) => ({
    serviceType,
    deliveryMethod,
    // a saldo's recipient is typed 'recarga': the service type, not the recipient, names the service
    beneficiaries: [{ beneficiaryType: "recarga" }],
  });

  it("names a saldo by its service type, not by its phone recipient (typed recarga)", () => {
    expect(currentServiceOf(op("saldo") as never)).toBe("saldo");
    expect(currentServiceOf(op("recarga") as never)).toBe("recarga");
  });

  it("keeps naming the other kinds as before", () => {
    expect(currentServiceOf(op("combo") as never)).toBe("combo");
    expect(currentServiceOf(op("visa") as never)).toBe("visa");
    expect(currentServiceOf(op("remesa", "zelle") as never)).toBe("zelle");
  });
});

describe("saldoPackages", () => {
  it("mirrors the database: 1,000 GYD per package carrying 360 of saldo", () => {
    expect(SALDO_PRICE_GYD).toBe(1000);
    expect(SALDO_UNIT_CUP).toBe(360);
  });

  it("counts whole packages", () => {
    expect(saldoPackages(1000)).toBe(1);
    expect(saldoPackages(5000)).toBe(5);
  });

  it("returns null for a deposit that is not a whole number of packages, or none (no rounding)", () => {
    expect(saldoPackages(5500)).toBeNull();
    expect(saldoPackages(500)).toBeNull();
    expect(saldoPackages(0)).toBeNull();
    expect(saldoPackages(null)).toBeNull();
    expect(saldoPackages(Number.NaN)).toBeNull();
  });
});
