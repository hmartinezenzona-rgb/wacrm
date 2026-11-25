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
      grand: { operations_gyd: "12000", adjustments_gyd: "-2000", total_gyd: "10000", resellers: 2 },
      resellers: [
        {
          contact_id: "contact-1",
          name: "Ana",
          phone: "+584120000000",
          period_start: "2026-11-01T10:00:00Z",
          operations_gyd: "9000",
          operations_count: 2,
          operations_missing_amount: 0,
          adjustments_gyd: "-1000",
          adjustments_count: 1,
          total_gyd: "8000",
        },
        {
          contact_id: "contact-2",
          name: null,
          phone: "+584120000001",
          period_start: null,
          operations_gyd: 3000,
          operations_count: 1,
          operations_missing_amount: 1,
          adjustments_gyd: -1000,
          adjustments_count: 1,
          total_gyd: 2000,
        },
      ],
    });

    expect(read.grand).toEqual({
      operationsGyd: 12000,
      adjustmentsGyd: -2000,
      totalGyd: 10000,
      resellers: 2,
    });
    expect(read.resellers).toHaveLength(2);
    expect(read.resellers[0]).toEqual({
      contactId: "contact-1",
      name: "Ana",
      phone: "+584120000000",
      periodStart: "2026-11-01T10:00:00Z",
      operationsGyd: 9000,
      operationsCount: 2,
      operationsMissingAmount: 0,
      adjustmentsGyd: -1000,
      adjustmentsCount: 1,
      totalGyd: 8000,
    });
    expect(read.resellers[1]).toMatchObject({
      contactId: "contact-2",
      name: null,
      periodStart: null,
      operationsMissingAmount: 1,
      totalGyd: 2000,
    });
  });

  it("returns zeros and an empty list for a null payload", () => {
    expect(mapResellerSummaryRead(null)).toEqual({
      grand: { operationsGyd: 0, adjustmentsGyd: 0, totalGyd: 0, resellers: 0 },
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
      current: {
        period_start: "2026-11-01T10:00:00Z",
        operations_gyd: "9000",
        operations_count: 2,
        operations_missing_amount: 0,
        adjustments_gyd: "-1000",
        adjustments_count: 1,
        total_gyd: "8000",
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
          operations_gyd: "2100",
          adjustments_gyd: 0,
          total_gyd: "2100",
          closed_total_gyd: "2100",
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
      current: {
        periodStart: "2026-11-01T10:00:00Z",
        operationsGyd: 9000,
        operationsCount: 2,
        operationsMissingAmount: 0,
        adjustmentsGyd: -1000,
        adjustmentsCount: 1,
        totalGyd: 8000,
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
          operationsGyd: 2100,
          adjustmentsGyd: 0,
          totalGyd: 2100,
          closedTotalGyd: 2100,
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
      current: {
        period_start: null,
        operations_gyd: 0,
        operations_count: 0,
        operations_missing_amount: 0,
        adjustments_gyd: 0,
        adjustments_count: 0,
        total_gyd: 0,
        adjustments: [],
      },
      periods: [],
    });

    expect(detail.isReseller).toBe(false);
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
        closed: { operations_gyd: "2100", adjustments_gyd: "0", total_gyd: "2100" },
      }),
    ).toEqual({
      resetId: "reset-1",
      contactId: "contact-1",
      resetAt: "2026-11-24T10:00:00Z",
      closed: { operationsGyd: 2100, adjustmentsGyd: 0, totalGyd: 2100 },
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
