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
 * Same convention as the /resumen legacy view (migration
 * 053_vistas_de_volumen.sql:127-128): first 4 digits + "****" + last 4
 * digits. Falls back to a flat mask of the same length for anything
 * shorter than 8 characters rather than reveal more than half of a short
 * value.
 */
export function maskCardNumber(cardNumber: string | null): string | null {
  if (!cardNumber) return null;
  if (cardNumber.length < 8) return "*".repeat(cardNumber.length);
  return `${cardNumber.slice(0, 4)}****${cardNumber.slice(-4)}`;
}

/**
 * No existing masking precedent for phone in this codebase (the /resumen
 * view leaves `celular_beneficiario` unmasked) — this panel masks it
 * anyway per product direction, keeping only the last 4 digits visible.
 */
export function maskPhone(phone: string | null): string | null {
  if (!phone) return null;
  if (phone.length <= 4) return "*".repeat(phone.length);
  return `${"*".repeat(phone.length - 4)}${phone.slice(-4)}`;
}

/**
 * Groups the RPC's flat (operation, beneficiary) rows into the panel's
 * nested read model, applying the masking helpers above. `rows` may be
 * empty (no session, defensive) or contain exactly one resolver-only row
 * (`resolverState === "ninguna"`, `operations: []`).
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
        adminLockedFields: row.operation_admin_locked_fields ?? {},
        createdAt: row.operation_created_at ?? new Date(0).toISOString(),
        completedAt: row.operation_completed_at,
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
        cardNumberMasked: maskCardNumber(row.beneficiary_card_number),
        phoneMasked: maskPhone(row.beneficiary_phone),
        zelleAccount: row.beneficiary_zelle_account,
        deliveryMethod: row.beneficiary_delivery_method,
        amount: toNullableNumber(row.beneficiary_amount),
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
