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
] as const;

export type OperationService = (typeof OPERATION_SERVICES)[number];

export function isOperationService(value: unknown): value is OperationService {
  return typeof value === "string" && (OPERATION_SERVICES as readonly string[]).includes(value);
}

/**
 * The service an operation currently has, as the "Servicio" field names it: recarga/combo/visa by service type,
 * otherwise the delivery method, otherwise the type of its first current recipient. `null` when none of them names a
 * service (e.g. a deposit-only remesa), so the field starts on its placeholder.
 */
export function currentServiceOf(
  operation: Pick<RemittanceOperationRead, "serviceType" | "deliveryMethod" | "beneficiaries">,
): OperationService | null {
  if (operation.serviceType === "recarga" || operation.serviceType === "combo" || operation.serviceType === "visa") {
    return operation.serviceType;
  }
  if (isOperationService(operation.deliveryMethod)) return operation.deliveryMethod;
  const first = operation.beneficiaries[0]?.beneficiaryType;
  return isOperationService(first) ? first : null;
}
