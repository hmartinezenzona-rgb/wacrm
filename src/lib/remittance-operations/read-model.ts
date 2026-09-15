// ============================================================
// Pure mapping from `crm_operaciones_de_conversacion`'s flat RPC rows
// (migration 097) into the panel's typed, nested read model. No I/O.
// ============================================================

import type {
  ConversationOperationsRead,
  RemittanceOperationRead,
  RemittanceOperationsRpcRow,
} from "./types";

function toNullableNumber(value: number | string | null): number | null {
  if (value === null) return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

/**
 * Groups the RPC's flat (operation, beneficiary) rows into the panel's
 * nested read model. `card_number`/`phone` are passed through raw
 * (unmasked) — product decision: operators need to copy them, and the
 * same values already appear in the conversation thread on this screen.
 * `rows` may be empty (no session, defensive) or contain exactly one
 * resolver-only row (`resolverState === "ninguna"`, `operations: []`).
 */
export function mapRemittanceOperationsRows(
  rows: RemittanceOperationsRpcRow[],
): ConversationOperationsRead {
  const first = rows[0];
  const resolverState = first?.resolver_resultado ?? "ninguna";
  const resolverOperationId = first?.resolver_operation_id ?? null;
  const resolverCandidateCount = first?.resolver_candidatas ?? 0;

  const operationsById = new Map<string, RemittanceOperationRead>();
  const order: string[] = [];

  for (const row of rows) {
    if (!row.operation_id) continue;

    let operation = operationsById.get(row.operation_id);
    if (!operation) {
      operation = {
        id: row.operation_id,
        // Non-null by construction: `operation_status` is only NULL on the
        // resolver-only row, which has no `operation_id` and never reaches
        // this branch.
        status: row.operation_status!,
        serviceType: row.operation_service_type ?? "remesa",
        sourceCurrency: row.operation_source_currency,
        destinationCurrency: row.operation_destination_currency,
        deliveryMethod: row.operation_delivery_method,
        depositMethod: row.operation_deposit_method,
        quotedSourceAmount: toNullableNumber(row.operation_quoted_source_amount),
        quotedDestinationAmount: toNullableNumber(row.operation_quoted_destination_amount),
        quotedDestinationRate: toNullableNumber(row.operation_quoted_destination_rate),
        quotedDestinationOrigin: row.operation_quoted_destination_origin ?? null,
        adminLockedFields: row.operation_admin_locked_fields ?? {},
        createdAt: row.operation_created_at ?? new Date(0).toISOString(),
        completedAt: row.operation_completed_at,
        isHistory: row.operation_is_history ?? false,
        beneficiariesComplete: row.operation_beneficiaries_complete ?? false,
        deliveryMode: row.operation_delivery_mode ?? null,
        deliveredAt: row.operation_delivered_at ?? null,
        beneficiaries: [],
      };
      operationsById.set(row.operation_id, operation);
      order.push(row.operation_id);
    }

    if (row.beneficiary_id) {
      operation.beneficiaries.push({
        id: row.beneficiary_id,
        beneficiaryType: row.beneficiary_type ?? "cuban_card",
        name: row.beneficiary_name,
        cardNumber: row.beneficiary_card_number,
        phone: row.beneficiary_phone,
        zelleAccount: row.beneficiary_zelle_account,
        deliveryMethod: row.beneficiary_delivery_method,
        amount: toNullableNumber(row.beneficiary_amount),
        amountOrigin: row.beneficiary_amount_origin ?? null,
        currency: row.beneficiary_currency,
        position: row.beneficiary_position ?? 1,
      });
    }
  }

  return {
    resolverState,
    resolverOperationId,
    resolverCandidateCount,
    // The RPC's own ORDER BY (o.created_at DESC, b.position ASC) already
    // yields the right operation order and beneficiary order within each
    // operation — `order` just preserves first-seen order per operation id.
    operations: order.map((id) => operationsById.get(id)!),
  };
}
