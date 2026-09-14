// Unit tests for the pure RPC-row -> panel read model mapping.
// Spec: chat-remesa-operations-panel ("List All Open Remesas Per
// Conversation", "Resolver State Handling"). Design decisions 2 (locks,
// read-through), masking convention from 053_vistas_de_volumen.sql.

import { describe, expect, it } from "vitest";
import { mapRemittanceOperationsRows, maskCardNumber, maskPhone } from "./read-model";
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
    beneficiary_currency: null,
    beneficiary_position: null,
    ...overrides,
  };
}

describe("maskCardNumber", () => {
  it("masks a normal card number as first4****last4 (resumen convention)", () => {
    expect(maskCardNumber("9205123412340009412")).toBe("9205****9412");
  });

  it("returns null for a null card number", () => {
    expect(maskCardNumber(null)).toBeNull();
  });

  it("fully masks a card number shorter than 8 characters", () => {
    expect(maskCardNumber("1234")).toBe("****");
  });
});

describe("maskPhone", () => {
  it("keeps only the last 4 digits visible", () => {
    expect(maskPhone("15550001111")).toBe("*******1111");
  });

  it("returns null for a null phone", () => {
    expect(maskPhone(null)).toBeNull();
  });

  it("fully masks a phone with 4 or fewer digits", () => {
    expect(maskPhone("123")).toBe("***");
  });
});

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
        operation_admin_locked_fields: {},
        operation_created_at: "2026-09-13T10:00:00Z",
        beneficiary_id: "ben-1",
        beneficiary_type: "cuban_card",
        beneficiary_name: "Yaima Perez",
        beneficiary_card_number: "9205123412340009412",
        beneficiary_phone: "15550001111",
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
    expect(op1?.beneficiaries[0].cardNumberMasked).toBe("9205****9412");
    expect(op1?.beneficiaries[0].phoneMasked).toBe("*******1111");
    expect(op1?.beneficiaries[1].zelleAccount).toBe("yaima@example.invalid");
    expect(op1?.quotedSourceAmount).toBe(10000);
    expect(op1?.quotedDestinationAmount).toBe(9800.5);
    expect(op2?.beneficiaries).toEqual([]);
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
