// ============================================================
// Pure mapping from `crm_comprobantes_de_operacion`'s / `crm_verificar_
// deposito`'s snake_case RPC payloads (migration 099) into the panel's
// typed, camelCase read models. No I/O.
// ============================================================

import type {
  DepositReceipt,
  DepositReceiptRpcRow,
  MatchedDeposit,
  MatchedDepositRpcRow,
  OperationReceiptsRead,
  OperationReceiptsRpcPayload,
  VerifyDepositResult,
  VerifyDepositRpcPayload,
} from "./types";

function toNullableNumber(
  value: number | string | null | undefined,
): number | null {
  if (value === null || value === undefined) return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function mapMatchedDeposit(raw: MatchedDepositRpcRow): MatchedDeposit {
  return {
    transId: raw.trans_id,
    amount: toNullableNumber(raw.amount),
    currency: raw.currency,
    receivedAt: raw.received_at,
    consumedAt: raw.consumed_at,
  };
}

function mapReceipt(raw: DepositReceiptRpcRow): DepositReceipt {
  return {
    compId: raw.comp_id,
    messageId: raw.message_id,
    mediaUrl: raw.media_url,
    receivedAt: raw.received_at,
    declaredAmount: toNullableNumber(raw.declared_amount),
    declaredCurrency: raw.declared_currency,
    declaredRef: raw.declared_ref,
    matchedDeposit: raw.matched_deposit
      ? mapMatchedDeposit(raw.matched_deposit)
      : null,
  };
}

/**
 * Maps `crm_comprobantes_de_operacion`'s raw payload into the panel's
 * `OperationReceiptsRead` shape. `receipts`/`consumed_deposits` may be
 * missing (defensive) and are treated as empty arrays.
 */
export function mapOperationReceiptsPayload(
  raw: OperationReceiptsRpcPayload,
): OperationReceiptsRead {
  return {
    operationId: raw.operation_id,
    status: raw.status,
    dealId: raw.deal_id,
    canVerify: Boolean(raw.can_verify),
    objetivo: toNullableNumber(raw.objetivo),
    depositado: toNullableNumber(raw.depositado),
    saldo: toNullableNumber(raw.saldo),
    moneda: raw.moneda,
    receipts: (raw.receipts ?? []).map(mapReceipt),
    consumedDeposits: (raw.consumed_deposits ?? []).map(mapMatchedDeposit),
  };
}

/**
 * Maps `crm_verificar_deposito`'s raw payload into the panel's
 * `VerifyDepositResult` shape.
 */
export function mapVerifyDepositPayload(
  raw: VerifyDepositRpcPayload,
): VerifyDepositResult {
  return {
    resultado: raw.resultado,
    metodo: raw.metodo,
    todosVerificados: Boolean(raw.todos_verificados),
    totalVerificado: toNullableNumber(raw.total_verificado),
    nComprobantes: toNullableNumber(raw.n_comprobantes),
    detalle: raw.detalle,
    objetivo: toNullableNumber(raw.objetivo),
    depositado: toNullableNumber(raw.depositado),
    saldo: toNullableNumber(raw.saldo),
    stageChanged: Boolean(raw.stage_changed),
    newStatus: raw.new_status,
  };
}
