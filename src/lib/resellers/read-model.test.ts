// Pure mapping from the 397 RPC jsonb payloads (snake_case) into the
// panel's typed camelCase read model. No I/O.

import { describe, expect, it } from "vitest";

import {
  mapAdjustmentResult,
  mapBatchResult,
  mapResellerDetail,
  mapResellerSummaryRead,
  mapResetResult,
} from "./read-model";

describe("mapResellerSummaryRead", () => {
  it("maps the grand total and every reseller row, coercing numeric strings", () => {
    const read = mapResellerSummaryRead({
      grand: {
        deposits_gyd: "15000",
        deposits_count: 3,
        operations_gyd: "12000",
        adjustments_gyd: "-2000",
        counted_gyd: "27000",
        total_gyd: "25000",
        resellers: 2,
      },
      resellers: [
        {
          contact_id: "contact-1",
          name: "Ana",
          phone: "+584120000000",
          period_start: "2026-11-01T10:00:00Z",
          deposits_gyd: "6000",
          deposits_count: 2,
          operations_gyd: "3000",
          operations_count: 1,
          operations_missing_amount: 0,
          adjustments_gyd: "-1000",
          adjustments_count: 1,
          counted_gyd: "9000",
          total_gyd: "8000",
        },
        {
          contact_id: "contact-2",
          name: null,
          phone: "+584120000001",
          period_start: null,
          deposits_gyd: 0,
          deposits_count: 0,
          operations_gyd: 3000,
          operations_count: 1,
          operations_missing_amount: 1,
          adjustments_gyd: -1000,
          adjustments_count: 1,
          counted_gyd: 3000,
          total_gyd: 2000,
        },
      ],
    });

    expect(read.grand).toEqual({
      depositsGyd: 15000,
      depositsCount: 3,
      operationsGyd: 12000,
      historicalOperationsGyd: 12000,
      adjustmentsGyd: -2000,
      countedGyd: 27000,
      totalGyd: 25000,
      resellers: 2,
    });
    expect(read.resellers).toHaveLength(2);
    expect(read.resellers[0]).toEqual({
      contactId: "contact-1",
      name: "Ana",
      phone: "+584120000000",
      periodStart: "2026-11-01T10:00:00Z",
      depositsGyd: 6000,
      depositsCount: 2,
      operationsGyd: 3000,
      historicalOperationsGyd: 3000,
      operationsCount: 1,
      operationsMissingAmount: 0,
      adjustmentsGyd: -1000,
      adjustmentsCount: 1,
      countedGyd: 9000,
      totalGyd: 8000,
    });
    expect(read.resellers[1]).toMatchObject({
      contactId: "contact-2",
      name: null,
      periodStart: null,
      depositsGyd: 0,
      operationsMissingAmount: 1,
      countedGyd: 3000,
      totalGyd: 2000,
    });
  });

  it("defaults the 398 deposit keys to zero when the payload is still 397-shaped", () => {
    const read = mapResellerSummaryRead({
      grand: { operations_gyd: "12000", adjustments_gyd: 0, total_gyd: "12000", resellers: 1 },
      resellers: [
        {
          contact_id: "contact-1",
          name: "Ana",
          phone: "1",
          period_start: null,
          operations_gyd: "12000",
          adjustments_gyd: 0,
          total_gyd: "12000",
        },
      ],
    });

    expect(read.grand.depositsGyd).toBe(0);
    expect(read.grand.depositsCount).toBe(0);
    expect(read.grand.countedGyd).toBe(0);
    expect(read.grand.historicalOperationsGyd).toBe(12000);
    expect(read.resellers[0]).toMatchObject({
      depositsGyd: 0,
      depositsCount: 0,
      countedGyd: 0,
      historicalOperationsGyd: 12000,
    });
  });

  it("returns zeros and an empty list for a null payload", () => {
    expect(mapResellerSummaryRead(null)).toEqual({
      grand: {
        depositsGyd: 0,
        depositsCount: 0,
        operationsGyd: 0,
        historicalOperationsGyd: 0,
        adjustmentsGyd: 0,
        countedGyd: 0,
        totalGyd: 0,
        resellers: 0,
      },
      resellers: [],
    });
  });

  it("preserves the payload order (no re-sorting)", () => {
    const read = mapResellerSummaryRead({
      grand: { operations_gyd: 0, adjustments_gyd: 0, total_gyd: 0, resellers: 2 },
      resellers: [
        { contact_id: "b", name: "B", phone: "2", period_start: null, total_gyd: 1 },
        { contact_id: "a", name: "A", phone: "1", period_start: null, total_gyd: 2 },
      ],
    });
    expect(read.resellers.map((r) => r.contactId)).toEqual(["b", "a"]);
  });
});

describe("mapResellerDetail", () => {
  it("maps contact, current period, adjustments and history periods", () => {
    const detail = mapResellerDetail({
      contact_id: "contact-1",
      name: "Ana",
      phone: "+584120000000",
      is_reseller: true,
      pending_claims: 2,
      current: {
        period_start: "2026-11-01T10:00:00Z",
        deposits_gyd: "5000",
        deposits_count: 2,
        operations_gyd: "9000",
        operations_count: 2,
        operations_missing_amount: 0,
        adjustments_gyd: "-1000",
        adjustments_count: 1,
        counted_gyd: "14000",
        total_gyd: "13000",
        adjustments: [
          {
            id: "adj-1",
            amount_gyd: "-1000",
            reason: "corrección",
            actor_name: "Admin",
            created_at: "2026-11-02T10:00:00Z",
          },
        ],
      },
      periods: [
        {
          reset_id: "reset-1",
          start: null,
          end: "2026-11-01T10:00:00Z",
          deposits_gyd: "1100",
          deposits_count: 1,
          operations_gyd: "1000",
          adjustments_gyd: 0,
          counted_gyd: "2100",
          total_gyd: "2100",
          closed_total_gyd: "2100",
          closed_deposits_gyd: "1100",
          batch_id: null,
          reset_by_name: "Admin",
          reason: null,
        },
      ],
    });

    expect(detail).toEqual({
      contactId: "contact-1",
      name: "Ana",
      phone: "+584120000000",
      isReseller: true,
      pendingClaims: 2,
      current: {
        periodStart: "2026-11-01T10:00:00Z",
        depositsGyd: 5000,
        depositsCount: 2,
        operationsGyd: 9000,
        historicalOperationsGyd: 9000,
        operationsCount: 2,
        operationsMissingAmount: 0,
        adjustmentsGyd: -1000,
        adjustmentsCount: 1,
        countedGyd: 14000,
        totalGyd: 13000,
        adjustments: [
          {
            id: "adj-1",
            amountGyd: -1000,
            reason: "corrección",
            actorName: "Admin",
            createdAt: "2026-11-02T10:00:00Z",
          },
        ],
      },
      periods: [
        {
          resetId: "reset-1",
          start: null,
          end: "2026-11-01T10:00:00Z",
          depositsGyd: 1100,
          depositsCount: 1,
          operationsGyd: 1000,
          historicalOperationsGyd: 1000,
          countedGyd: 2100,
          adjustmentsGyd: 0,
          totalGyd: 2100,
          closedTotalGyd: 2100,
          closedDepositsGyd: 1100,
          batchId: null,
          resetByName: "Admin",
          reason: null,
        },
      ],
    });
  });

  it("keeps is_reseller false with empty current lists when the contact is untagged", () => {
    const detail = mapResellerDetail({
      contact_id: "contact-9",
      name: null,
      phone: "+584120000009",
      is_reseller: false,
      pending_claims: 0,
      current: {
        period_start: null,
        deposits_gyd: 0,
        deposits_count: 0,
        operations_gyd: 0,
        operations_count: 0,
        operations_missing_amount: 0,
        adjustments_gyd: 0,
        adjustments_count: 0,
        counted_gyd: 0,
        total_gyd: 0,
        adjustments: [],
      },
      periods: [],
    });

    expect(detail.isReseller).toBe(false);
    expect(detail.pendingClaims).toBe(0);
    expect(detail.current.adjustments).toEqual([]);
    expect(detail.periods).toEqual([]);
    expect(detail.name).toBeNull();
    expect(detail.current.periodStart).toBeNull();
  });
});

describe("mapAdjustmentResult", () => {
  it("maps the adjustment outcome", () => {
    expect(
      mapAdjustmentResult({
        adjustment_id: "adj-1",
        contact_id: "contact-1",
        amount_gyd: "-1000",
        created_at: "2026-11-02T10:00:00Z",
        total_before_gyd: "9000",
        total_after_gyd: "8000",
      }),
    ).toEqual({
      adjustmentId: "adj-1",
      contactId: "contact-1",
      amountGyd: -1000,
      createdAt: "2026-11-02T10:00:00Z",
      totalBeforeGyd: 9000,
      totalAfterGyd: 8000,
    });
  });
});

describe("mapResetResult", () => {
  it("maps the reset marker and its closed snapshot", () => {
    expect(
      mapResetResult({
        reset_id: "reset-1",
        contact_id: "contact-1",
        reset_at: "2026-11-24T10:00:00Z",
        closed: {
          deposits_gyd: "1600",
          operations_gyd: "500",
          adjustments_gyd: "0",
          counted_gyd: "2100",
          total_gyd: "2100",
        },
      }),
    ).toEqual({
      resetId: "reset-1",
      contactId: "contact-1",
      resetAt: "2026-11-24T10:00:00Z",
      closed: {
        depositsGyd: 1600,
        operationsGyd: 500,
        historicalOperationsGyd: 500,
        adjustmentsGyd: 0,
        countedGyd: 2100,
        totalGyd: 2100,
      },
    });
  });
});

describe("mapBatchResult", () => {
  it("maps the reset-all batch with the resellers actually closed", () => {
    expect(
      mapBatchResult({
        batch_id: "batch-1",
        reset_at: "2026-11-24T10:00:00Z",
        count: 1,
        grand_total_gyd: "2100",
        resets: [{ reset_id: "reset-1", contact_id: "contact-1", total_gyd: "2100" }],
      }),
    ).toEqual({
      batchId: "batch-1",
      resetAt: "2026-11-24T10:00:00Z",
      count: 1,
      grandTotalGyd: 2100,
      resets: [{ resetId: "reset-1", contactId: "contact-1", totalGyd: 2100 }],
    });
  });

  it("maps an empty batch (all resellers at zero, none closed)", () => {
    expect(
      mapBatchResult({
        batch_id: "batch-2",
        reset_at: "2026-11-24T11:00:00Z",
        count: 0,
        grand_total_gyd: 0,
        resets: [],
      }),
    ).toMatchObject({ count: 0, grandTotalGyd: 0, resets: [] });
  });
});
