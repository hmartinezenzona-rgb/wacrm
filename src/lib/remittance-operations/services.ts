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
