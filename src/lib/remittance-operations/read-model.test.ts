// Unit tests for the pure RPC-row -> panel read model mapping.
// Spec: chat-remesa-operations-panel ("List All Open Remesas Per
// Conversation", "Resolver State Handling"). Design decisions 2 (locks,
// read-through). Card/phone are passed through raw (unmasked) — product
// decision: operators need to copy them, and the same values already
// appear in the conversation thread on this screen.

import { describe, expect, it } from "vitest";
import { mapQuoteRows, mapRemittanceOperationsRows } from "./read-model";
import type { RemittanceOperationsRpcRow } from "./types";

function row(overrides: Partial<RemittanceOperationsRpcRow>): RemittanceOperationsRpcRow {
  return {
    resolver_resultado: "ninguna",
    resolver_operation_id: null,
    resolver_candidatas: 0,
    operation_id: null,
    operation_status: null,
    operation_service_type: null,
    operation_source_currency: null,
    operation_destination_currency: null,
    operation_delivery_method: null,
    operation_deposit_method: null,
    operation_quoted_source_amount: null,
    operation_quoted_destination_amount: null,
    operation_quoted_destination_rate: null,
    operation_quoted_destination_origin: null,
    operation_admin_locked_fields: null,
    operation_created_at: null,
    operation_completed_at: null,
    beneficiary_id: null,
    beneficiary_type: null,
    beneficiary_name: null,
    beneficiary_card_number: null,
    beneficiary_phone: null,
    beneficiary_zelle_account: null,
    beneficiary_delivery_method: null,
    beneficiary_amount: null,
    beneficiary_amount_origin: null,
    beneficiary_currency: null,
    beneficiary_position: null,
    operation_is_history: null,
    operation_beneficiaries_complete: null,
    operation_delivery_mode: null,
    operation_delivered_at: null,
    ...overrides,
  };
}

describe("mapRemittanceOperationsRows", () => {
  it("maps a conversation with two open remesas, one with two beneficiaries", () => {
    const rows: RemittanceOperationsRpcRow[] = [
      row({
        resolver_resultado: "ambigua",
        resolver_operation_id: null,
        resolver_candidatas: 2,
        operation_id: "op-1",
        operation_status: "deposit_verification",
        operation_service_type: "remesa",
        operation_source_currency: "GYD",
        operation_destination_currency: "CUP",
        operation_quoted_source_amount: 10000,
        operation_quoted_destination_amount: "9800.50",
        operation_quoted_destination_rate: "1.02",
        operation_quoted_destination_origin: "calculated",
        operation_admin_locked_fields: {},
        operation_created_at: "2026-09-13T10:00:00Z",
        beneficiary_id: "ben-1",
        beneficiary_type: "cuban_card",
        beneficiary_name: "Yaima Perez",
        beneficiary_card_number: "9205123412340009412",
        beneficiary_phone: "15550001111",
        beneficiary_amount_origin: "manual",
        beneficiary_position: 1,
      }),
      row({
        resolver_resultado: "ambigua",
        resolver_operation_id: null,
        resolver_candidatas: 2,
        operation_id: "op-1",
        operation_status: "deposit_verification",
        operation_service_type: "remesa",
        operation_source_currency: "GYD",
        operation_destination_currency: "CUP",
        operation_quoted_source_amount: 10000,
        operation_quoted_destination_amount: "9800.50",
        operation_admin_locked_fields: {},
        operation_created_at: "2026-09-13T10:00:00Z",
        beneficiary_id: "ben-2",
        beneficiary_type: "zelle",
        beneficiary_name: "Yaima Perez Zelle",
        beneficiary_zelle_account: "yaima@example.invalid",
        beneficiary_position: 2,
      }),
      row({
        resolver_resultado: "ambigua",
        resolver_operation_id: null,
        resolver_candidatas: 2,
        operation_id: "op-2",
        operation_status: "awaiting_deposit",
        operation_service_type: "remesa",
        operation_source_currency: "GYD",
        operation_created_at: "2026-09-13T09:00:00Z",
        // op-2 has zero beneficiaries: beneficiary_* stays NULL (LEFT JOIN).
      }),
    ];

    const result = mapRemittanceOperationsRows(rows);

    expect(result.operations).toHaveLength(2);
    const op1 = result.operations.find((operation) => operation.id === "op-1");
    const op2 = result.operations.find((operation) => operation.id === "op-2");
    expect(op1?.beneficiaries).toHaveLength(2);
    expect(op1?.beneficiaries.map((b) => b.id)).toEqual(["ben-1", "ben-2"]);
    expect(op1?.beneficiaries[0].cardNumber).toBe("9205123412340009412");
    expect(op1?.beneficiaries[0].phone).toBe("15550001111");
    expect(op1?.beneficiaries[1].zelleAccount).toBe("yaima@example.invalid");
    expect(op1?.quotedSourceAmount).toBe(10000);
    expect(op1?.quotedDestinationAmount).toBe(9800.5);
    expect(op1?.quotedDestinationRate).toBe(1.02);
    expect(op1?.quotedDestinationOrigin).toBe("calculated");
    expect(op1?.beneficiaries[0].amountOrigin).toBe("manual");
    expect(op2?.beneficiaries).toEqual([]);
  });

  it("maps history/readiness/delivery columns (migration 102)", () => {
    const rows: RemittanceOperationsRpcRow[] = [
      row({
        operation_id: "op-1",
        operation_status: "completed",
        operation_service_type: "remesa",
        operation_created_at: "2026-09-10T10:00:00Z",
        operation_completed_at: "2026-09-14T12:30:00Z",
        operation_is_history: true,
        operation_beneficiaries_complete: true,
        operation_delivery_mode: "proof_sent",
        operation_delivered_at: "2026-09-14T12:30:00Z",
      }),
    ];

    const result = mapRemittanceOperationsRows(rows);

    const op1 = result.operations[0];
    expect(op1.isHistory).toBe(true);
    expect(op1.beneficiariesComplete).toBe(true);
    expect(op1.deliveryMode).toBe("proof_sent");
    expect(op1.deliveredAt).toBe("2026-09-14T12:30:00Z");
  });

  it("defaults isHistory/beneficiariesComplete/deliveryMode/deliveredAt when the RPC omits them", () => {
    const rows: RemittanceOperationsRpcRow[] = [
      row({
        operation_id: "op-1",
        operation_status: "collecting_information",
        operation_service_type: "remesa",
        operation_created_at: "2026-09-13T10:00:00Z",
      }),
    ];

    const result = mapRemittanceOperationsRows(rows);

    const op1 = result.operations[0];
    expect(op1.isHistory).toBe(false);
    expect(op1.beneficiariesComplete).toBe(false);
    expect(op1.deliveryMode).toBeNull();
    expect(op1.deliveredAt).toBeNull();
  });

  it("defaults quotedDestinationRate/quotedDestinationOrigin/amountOrigin to null when the RPC omits them", () => {
    const rows: RemittanceOperationsRpcRow[] = [
      row({
        operation_id: "op-1",
        operation_status: "collecting_information",
        operation_service_type: "remesa",
        operation_created_at: "2026-09-13T10:00:00Z",
        beneficiary_id: "ben-1",
        beneficiary_type: "cuban_card",
        beneficiary_position: 1,
      }),
    ];

    const result = mapRemittanceOperationsRows(rows);

    const op1 = result.operations[0];
    expect(op1.quotedDestinationRate).toBeNull();
    expect(op1.quotedDestinationOrigin).toBeNull();
    expect(op1.beneficiaries[0].amountOrigin).toBeNull();
  });

  it("surfaces ambigua explicitly without picking a winner operation", () => {
    const rows: RemittanceOperationsRpcRow[] = [
      row({
        resolver_resultado: "ambigua",
        resolver_operation_id: null,
        resolver_candidatas: 2,
        operation_id: "op-1",
        operation_status: "collecting_information",
        operation_service_type: "remesa",
        operation_created_at: "2026-09-13T10:00:00Z",
      }),
      row({
        resolver_resultado: "ambigua",
        resolver_operation_id: null,
        resolver_candidatas: 2,
        operation_id: "op-2",
        operation_status: "collecting_information",
        operation_service_type: "remesa",
        operation_created_at: "2026-09-13T09:00:00Z",
      }),
    ];

    const result = mapRemittanceOperationsRows(rows);

    expect(result.resolverState).toBe("ambigua");
    expect(result.resolverOperationId).toBeNull();
    expect(result.resolverCandidateCount).toBe(2);
    // Both operations are still listed — resolver "not guessing" means not
    // auto-selecting one, not hiding the data (spec: "List All Open Remesas").
    expect(result.operations.map((o) => o.id).sort()).toEqual(["op-1", "op-2"]);
  });

  it("shows nothing and fabricates no operation when the resolver reports ninguna", () => {
    const rows: RemittanceOperationsRpcRow[] = [
      row({ resolver_resultado: "ninguna", resolver_operation_id: null, resolver_candidatas: 0 }),
    ];

    const result = mapRemittanceOperationsRows(rows);

    expect(result.resolverState).toBe("ninguna");
    expect(result.resolverCandidateCount).toBe(0);
    expect(result.operations).toEqual([]);
  });

  it("defaults to ninguna with no operations for an empty row array (defensive)", () => {
    const result = mapRemittanceOperationsRows([]);

    expect(result.resolverState).toBe("ninguna");
    expect(result.operations).toEqual([]);
  });
});

describe("mapQuoteRows", () => {
  it("maps the single row to camelCase", () => {
    expect(
      mapQuoteRows([
        { gyd: 5000, destino_monto: 15000, destino_moneda: "CUP", cotizado_en: "2026-10-02T10:00:00Z" },
      ]),
    ).toEqual({ gyd: 5000, destinationAmount: 15000, destinationCurrency: "CUP", quotedAt: "2026-10-02T10:00:00Z" });
  });

  it("coerces PostgREST numeric strings to numbers", () => {
    const quote = mapQuoteRows([
      { gyd: "26000.00", destino_monto: "100", destino_moneda: "USD", cotizado_en: "2026-10-02T10:00:00Z" },
    ]);
    expect(quote?.gyd).toBe(26000);
    expect(quote?.destinationAmount).toBe(100);
    expect(quote?.destinationCurrency).toBe("USD");
  });

  it("keeps a missing destination as nulls", () => {
    expect(
      mapQuoteRows([{ gyd: 5000, destino_monto: null, destino_moneda: null, cotizado_en: "2026-10-02T10:00:00Z" }]),
    ).toEqual({ gyd: 5000, destinationAmount: null, destinationCurrency: null, quotedAt: "2026-10-02T10:00:00Z" });
  });

  it("drops an unknown destination currency", () => {
    const quote = mapQuoteRows([
      { gyd: 5000, destino_monto: 10, destino_moneda: "EUR", cotizado_en: "2026-10-02T10:00:00Z" },
    ]);
    expect(quote?.destinationCurrency).toBeNull();
  });

  it("returns null for no rows, null data or a non-numeric gyd", () => {
    expect(mapQuoteRows([])).toBeNull();
    expect(mapQuoteRows(null)).toBeNull();
    expect(
      mapQuoteRows([{ gyd: "abc", destino_monto: null, destino_moneda: null, cotizado_en: "2026-10-02T10:00:00Z" }]),
    ).toBeNull();
  });
});
