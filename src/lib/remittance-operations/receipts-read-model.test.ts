// Unit tests for the pure RPC-payload -> deposit receipts read model
// mapping. Spec: deposit-verification-review. Covers full payload
// mapping, null deal / empty arrays, numeric-string coercion, and a
// null matched_deposit staying null.

import { describe, expect, it } from "vitest";
import {
  mapOperationReceiptsPayload,
  mapVerifyDepositPayload,
} from "./receipts-read-model";
import type {
  OperationReceiptsRpcPayload,
  VerifyDepositRpcPayload,
} from "./types";

const OPERATION_ID = "11111111-1111-1111-1111-111111111111";
const DEAL_ID = "22222222-2222-2222-2222-222222222222";

function payload(
  overrides: Partial<OperationReceiptsRpcPayload>,
): OperationReceiptsRpcPayload {
  return {
    operation_id: OPERATION_ID,
    status: "deposit_verification",
    deal_id: DEAL_ID,
    can_verify: true,
    objetivo: 25000,
    depositado: 25000,
    saldo: 0,
    moneda: "GYD",
    receipts: [],
    consumed_deposits: [],
    ...overrides,
  };
}

describe("mapOperationReceiptsPayload", () => {
  it("maps a full payload with a matched receipt and a consumed deposit", () => {
    const raw = payload({
      receipts: [
        {
          comp_id: "comp-1",
          message_id: "msg-1",
          media_url: "https://example.invalid/comp-1.jpg",
          received_at: "2026-09-14T10:00:00Z",
          declared_amount: 25000,
          declared_currency: "GYD",
          declared_ref: "TX-1",
          matched_deposit: {
            trans_id: "trans-1",
            amount: 25000,
            currency: "GYD",
            received_at: "2026-09-14T10:05:00Z",
            consumed_at: "2026-09-14T10:06:00Z",
          },
        },
      ],
      consumed_deposits: [
        {
          trans_id: "trans-1",
          amount: 25000,
          currency: "GYD",
          received_at: "2026-09-14T10:05:00Z",
          consumed_at: "2026-09-14T10:06:00Z",
        },
      ],
    });

    const result = mapOperationReceiptsPayload(raw);

    expect(result).toEqual({
      operationId: OPERATION_ID,
      status: "deposit_verification",
      dealId: DEAL_ID,
      canVerify: true,
      objetivo: 25000,
      depositado: 25000,
      saldo: 0,
      moneda: "GYD",
      receipts: [
        {
          compId: "comp-1",
          messageId: "msg-1",
          mediaUrl: "https://example.invalid/comp-1.jpg",
          receivedAt: "2026-09-14T10:00:00Z",
          declaredAmount: 25000,
          declaredCurrency: "GYD",
          declaredRef: "TX-1",
          matchedDeposit: {
            transId: "trans-1",
            amount: 25000,
            currency: "GYD",
            receivedAt: "2026-09-14T10:05:00Z",
            consumedAt: "2026-09-14T10:06:00Z",
          },
        },
      ],
      consumedDeposits: [
        {
          transId: "trans-1",
          amount: 25000,
          currency: "GYD",
          receivedAt: "2026-09-14T10:05:00Z",
          consumedAt: "2026-09-14T10:06:00Z",
        },
      ],
    });
  });

  it("handles a null deal and missing receipts/consumed_deposits arrays", () => {
    const raw = payload({
      deal_id: null,
      objetivo: null,
      depositado: null,
      saldo: null,
      moneda: null,
      receipts: null,
      consumed_deposits: null,
    });

    const result = mapOperationReceiptsPayload(raw);

    expect(result.dealId).toBeNull();
    expect(result.objetivo).toBeNull();
    expect(result.receipts).toEqual([]);
    expect(result.consumedDeposits).toEqual([]);
  });

  it("coerces numeric strings to numbers", () => {
    const raw = payload({
      objetivo: "25000",
      depositado: "25000",
      saldo: "0",
      receipts: [
        {
          comp_id: "comp-1",
          message_id: null,
          media_url: null,
          received_at: null,
          declared_amount: "25000",
          declared_currency: "GYD",
          declared_ref: null,
          matched_deposit: null,
        },
      ],
    });

    const result = mapOperationReceiptsPayload(raw);

    expect(result.objetivo).toBe(25000);
    expect(result.depositado).toBe(25000);
    expect(result.saldo).toBe(0);
    expect(result.receipts[0].declaredAmount).toBe(25000);
  });

  it("preserves a null matched_deposit on a receipt", () => {
    const raw = payload({
      receipts: [
        {
          comp_id: "comp-1",
          message_id: null,
          media_url: null,
          received_at: null,
          declared_amount: null,
          declared_currency: null,
          declared_ref: null,
          matched_deposit: null,
        },
      ],
    });

    const result = mapOperationReceiptsPayload(raw);

    expect(result.receipts[0].matchedDeposit).toBeNull();
  });
});

function verifyPayload(
  overrides: Partial<VerifyDepositRpcPayload>,
): VerifyDepositRpcPayload {
  return {
    resultado: "verificado",
    metodo: "manual",
    todos_verificados: true,
    total_verificado: 25000,
    n_comprobantes: 1,
    detalle: { items: [] },
    objetivo: 25000,
    depositado: 25000,
    saldo: 0,
    stage_changed: true,
    new_status: "ready_to_transfer",
    ...overrides,
  };
}

describe("mapVerifyDepositPayload", () => {
  it("maps a full verify-deposit payload", () => {
    const raw = verifyPayload({});

    const result = mapVerifyDepositPayload(raw);

    expect(result).toEqual({
      resultado: "verificado",
      metodo: "manual",
      todosVerificados: true,
      totalVerificado: 25000,
      nComprobantes: 1,
      detalle: { items: [] },
      objetivo: 25000,
      depositado: 25000,
      saldo: 0,
      stageChanged: true,
      newStatus: "ready_to_transfer",
    });
  });

  it("coerces numeric strings to numbers and preserves nulls", () => {
    const raw = verifyPayload({
      metodo: null,
      total_verificado: "25000",
      n_comprobantes: "1",
      objetivo: null,
      depositado: null,
      saldo: null,
    });

    const result = mapVerifyDepositPayload(raw);

    expect(result.metodo).toBeNull();
    expect(result.totalVerificado).toBe(25000);
    expect(result.nComprobantes).toBe(1);
    expect(result.objetivo).toBeNull();
    expect(result.depositado).toBeNull();
    expect(result.saldo).toBeNull();
  });
});
