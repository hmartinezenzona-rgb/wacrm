/**
 * Service colours — one fixed colour per service, the same on every screen.
 *
 * Both vocabularies are covered: the ledger services of the calculator and Finanzas (CUP, ZELLE, SALDO_MOVIL,
 * DIRECTO…) and the operation `service_type` / delivery-method values (remesa, visa, recarga, cuban_card…). The
 * colours live in globals.css as --service-* tokens, independent of the accent theme. A dot always sits next to the
 * service name, so colour is never the only cue. Class names are written out in full for Tailwind.
 */

export const SERVICE_COLORS = [
  "cup",
  "zelle",
  "mlc",
  "tropical",
  "clasica",
  "usdt",
  "efectivo",
  "recarga",
  "saldo",
  "directo",
  "remesa",
  "visa",
  "other",
] as const;

export type ServiceColor = (typeof SERVICE_COLORS)[number];

// Keys are lower case; the lookup lower-cases its input. combo / traduccion / mexico are filed under the ledger's
// DIRECTO ("Trámites / Combos / Servicios"), which is where their money lands.
const COLOR_BY_SERVICE: Record<string, ServiceColor> = {
  cup: "cup",
  cuban_card: "cup",
  zelle: "zelle",
  mlc: "mlc",
  tropical: "tropical",
  clasica: "clasica",
  usdt: "usdt",
  efectivo: "efectivo",
  efectivo_usd: "efectivo",
  recarga: "recarga",
  saldo_movil: "saldo",
  saldo: "saldo",
  directo: "directo",
  combo: "directo",
  traduccion: "directo",
  mexico: "directo",
  remesa: "remesa",
  visa: "visa",
};

/** Colour of a service key; an unknown, empty or missing one is `other` (a neutral dot). */
export function serviceColor(service: string | null | undefined): ServiceColor {
  if (!service) return "other";
  const key = service.toLowerCase();
  return Object.prototype.hasOwnProperty.call(COLOR_BY_SERVICE, key) ? COLOR_BY_SERVICE[key] : "other";
}

/** Background class of the dot. */
export const serviceDotClass: Record<ServiceColor, string> = {
  cup: "bg-service-cup",
  zelle: "bg-service-zelle",
  mlc: "bg-service-mlc",
  tropical: "bg-service-tropical",
  clasica: "bg-service-clasica",
  usdt: "bg-service-usdt",
  efectivo: "bg-service-efectivo",
  recarga: "bg-service-recarga",
  saldo: "bg-service-saldo",
  directo: "bg-service-directo",
  remesa: "bg-service-remesa",
  visa: "bg-service-visa",
  other: "bg-service-other",
};
