/**
 * Service names — one canonical id and one display name per service, on every screen.
 *
 * The app speaks two vocabularies: the ledger services of the Calculator and Finanzas (CUP, ZELLE, SALDO_MOVIL,
 * DIRECTO…) and the operation side (service_type remesa/combo/recarga/visa/saldo/traduccion/mexico, plus the delivery
 * methods and beneficiary types cuban_card/zelle/clasica…). Both resolve here to one canonical id, and the name is read
 * from the `ServiceNames` namespace of messages/{es,en}.json (next-intl screens) or from `SERVICE_NAMES_ES` (screens
 * without next-intl; a test proves the table equals es.json). Display only: the keys sent to the API and the database
 * never change.
 */

export const SERVICE_IDS = [
  "cup",
  "zelle",
  "clasica",
  "tropical",
  "mlc",
  "usdt",
  "efectivo_usd",
  "recarga",
  "saldo",
  "combo",
  "visa",
  "tramites",
  "traduccion",
  "mexico",
  "mixed",
  "remesa",
] as const;

export type ServiceId = (typeof SERVICE_IDS)[number];

/** Spanish display names, the owner's canonical spellings. Equal to the `ServiceNames` namespace of es.json. */
export const SERVICE_NAMES_ES: Record<ServiceId, string> = {
  cup: "CUP",
  zelle: "Zelle",
  clasica: "Clásica",
  tropical: "Tropical",
  mlc: "MLC",
  usdt: "USDT",
  efectivo_usd: "Efectivo USD",
  recarga: "Recarga",
  saldo: "Saldo móvil",
  combo: "Combo",
  visa: "Visa",
  tramites: "Trámites",
  traduccion: "Traducción",
  mexico: "México",
  mixed: "Remesa mixta",
  remesa: "Remesa",
};

// Keys are normalised (lower case, no accents, spaces and hyphens as "_"): "SALDO MOVIL", "Saldo Móvil" and
// "saldo_movil" are one key. combo / traduccion / mexico keep their own names even though the ledger files their money
// under DIRECTO ("Trámites").
const ID_BY_KEY: Record<string, ServiceId> = {
  // ledger services
  cup: "cup",
  zelle: "zelle",
  mlc: "mlc",
  clasica: "clasica",
  tropical: "tropical",
  usdt: "usdt",
  efectivo: "efectivo_usd",
  recarga: "recarga",
  saldo_movil: "saldo",
  combo: "combo",
  visa: "visa",
  directo: "tramites",
  // delivery methods, beneficiary types and OperationService
  cuban_card: "cup",
  efectivo_usd: "efectivo_usd",
  saldo: "saldo",
  multiple_distribution: "mixed",
  // service types
  remesa: "remesa",
  traduccion: "traduccion",
  mexico: "mexico",
  // the canonical ids that no other key spells
  tramites: "tramites",
  mixed: "mixed",
  // the history's ledger-style service of a remittance split over several kinds (migration 229)
  mixta: "mixed",
};

function normaliseKey(key: string): string {
  return key
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
}

/** Canonical id of a key of either vocabulary; `null` for an unknown, empty or missing one (callers print the raw value). */
export function resolveServiceId(key: string | null | undefined): ServiceId | null {
  if (!key) return null;
  const normalised = normaliseKey(key);
  return Object.prototype.hasOwnProperty.call(ID_BY_KEY, normalised) ? ID_BY_KEY[normalised] : null;
}

/** Spanish name of a key of either vocabulary, or `null` when it is unknown. */
export function serviceNameEs(key: string | null | undefined): string | null {
  const id = resolveServiceId(key);
  return id ? SERVICE_NAMES_ES[id] : null;
}

/** Service types that name the operation whatever its recipients or delivery method say. */
const TYPE_NAMED_SERVICES: ReadonlySet<ServiceId> = new Set(["recarga", "combo", "visa", "saldo", "traduccion", "mexico"]);

export interface OperationNameInput {
  serviceType?: string | null;
  deliveryMethod?: string | null;
  /** `beneficiary_type` of the operation's current recipients, when the screen has them. */
  beneficiaryTypes?: ReadonlyArray<string | null | undefined> | null;
}

/**
 * The service an operation is named after, with the precedence of `calculator_resolve_operation_service` (migration
 * 223): a recarga / combo / visa / saldo service type wins; else its current recipients (one kind names it, more than
 * one kind is a mixed remittance); else the delivery method (`multiple_distribution` is mixed); else the generic
 * "remesa", only for a screen that truly cannot know the rail. A traduccion / mexico service type names itself (the
 * database files them under the generic ledger service, but they have names of their own).
 */
export function operationServiceId(operation: OperationNameInput): ServiceId {
  const byType = resolveServiceId(operation.serviceType);
  if (byType && TYPE_NAMED_SERVICES.has(byType)) return byType;
  const kinds = new Set<ServiceId>();
  for (const type of operation.beneficiaryTypes ?? []) {
    const id = resolveServiceId(type);
    if (id) kinds.add(id);
  }
  if (kinds.size > 1) return "mixed";
  if (kinds.size === 1) return [...kinds][0];
  const byDelivery = resolveServiceId(operation.deliveryMethod);
  return byDelivery ?? "remesa";
}
