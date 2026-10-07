import type { RemittanceOperationRead } from "./types";

// The services an open operation can be switched to (crm_cambiar_servicio, migration 222). Shared by the API route
// (validation) and the panel's "Servicio" selector (options), so the two cannot drift apart.

export const OPERATION_SERVICES = [
  "cuban_card",
  "zelle",
  "clasica",
  "tropical",
  "efectivo_usd",
  "recarga",
  "combo",
  "visa",
  "saldo",
] as const;

export type OperationService = (typeof OPERATION_SERVICES)[number];

export function isOperationService(value: unknown): value is OperationService {
  return typeof value === "string" && (OPERATION_SERVICES as readonly string[]).includes(value);
}

/**
 * The service an operation currently has, as the "Servicio" field names it: recarga/combo/visa/saldo by service type,
 * otherwise the delivery method, otherwise the type of its first current recipient. `null` when none of them names a
 * service (e.g. a deposit-only remesa), so the field starts on its placeholder.
 */
export function currentServiceOf(
  operation: Pick<RemittanceOperationRead, "serviceType" | "deliveryMethod" | "beneficiaries">,
): OperationService | null {
  if (
    operation.serviceType === "recarga" ||
    operation.serviceType === "combo" ||
    operation.serviceType === "visa" ||
    operation.serviceType === "saldo"
  ) {
    return operation.serviceType;
  }
  if (isOperationService(operation.deliveryMethod)) return operation.deliveryMethod;
  const first = operation.beneficiaries[0]?.beneficiaryType;
  return isOperationService(first) ? first : null;
}

/** Price in GYD of one package of mobile balance and the saldo (CUP) it carries (migration 223: cerebro_config
 *  precio_saldo_gyd and saldo_unidad_cup). Mirrored here, as VISA_PRICE_GYD is for a visa, so the card can show the
 *  count without a round trip; change both together. */
export const SALDO_PRICE_GYD = 1000;
export const SALDO_UNIT_CUP = 360;

/** Packages in a saldo deposit, or `null` when the deposit is not a whole number of them (the ledger line stays
 *  pending for a person: no silent rounding). */
export function saldoPackages(amountGyd: number | null): number | null {
  if (amountGyd === null || !Number.isFinite(amountGyd) || amountGyd <= 0) return null;
  return amountGyd % SALDO_PRICE_GYD === 0 ? amountGyd / SALDO_PRICE_GYD : null;
}
