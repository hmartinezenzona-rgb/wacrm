// Pure rules of "Registros de la semana": which status a line has, the filters over the one table and the totals of
// what the filters leave. No I/O. Only completed lines add to a total; a line waiting for a rate never does.

import { canResolveWithRates } from "@/lib/calculator/ledger-read-model";

export interface RegistroEntry {
  id: string;
  operationId: string | null;
  source: "completed_operation" | "manual";
  status: string;
  service: string;
  customerName: string | null;
  entryDate: string;
  facturadoGyd: number | null;
  invertidoGyd: number | null;
  retornoGyd: number | null;
  missingRates: string[];
}

/** completed; sinTasa = waiting for a rate somebody can set; pending = any other line still waiting (a COMBO waiting for its cost). */
export type EntryGroup = "completed" | "pending" | "sinTasa";

export function entryGroup(entry: Pick<RegistroEntry, "status" | "service" | "missingRates">): EntryGroup {
  if (entry.status === "completed") return "completed";
  if (entry.status === "verified_pending" && canResolveWithRates(entry as Parameters<typeof canResolveWithRates>[0]) && entry.missingRates.length > 0) return "sinTasa";
  return "pending";
}

export type StatusFilter = "all" | "completed" | "pending" | "sinTasa" | "manual";

export interface RegistroFilters {
  status: StatusFilter;
  /** A ledger service key. */
  service: string | null;
  /** A client name, matched ignoring case and surrounding spaces. */
  client: string | null;
  query: string;
}

export const NO_FILTERS: RegistroFilters = { status: "all", service: null, client: null, query: "" };

const norm = (value: string | null | undefined) => (value ?? "").trim().toLocaleLowerCase();

export function sameClient(a: string | null | undefined, b: string | null | undefined): boolean {
  return norm(a) !== "" && norm(a) === norm(b);
}

function matchesStatus(entry: RegistroEntry, status: StatusFilter): boolean {
  if (status === "all") return true;
  if (status === "manual") return entry.source === "manual";
  return entryGroup(entry) === status;
}

function matchesQuery(entry: RegistroEntry, query: string): boolean {
  const q = norm(query);
  if (!q) return true;
  return norm(entry.customerName).includes(q) || norm(entry.operationId).includes(q);
}

function matchesOthers(entry: RegistroEntry, filters: RegistroFilters): boolean {
  if (filters.service && entry.service !== filters.service) return false;
  if (filters.client && !sameClient(entry.customerName, filters.client)) return false;
  return matchesQuery(entry, filters.query);
}

export function filterRegistros<T extends RegistroEntry>(entries: T[], filters: RegistroFilters): T[] {
  return entries.filter((entry) => matchesStatus(entry, filters.status) && matchesOthers(entry, filters));
}

/** The chip counts: each over the lines the service, client and search filters leave (the chosen status is ignored). */
export function statusCounts(entries: RegistroEntry[], filters: RegistroFilters): Record<StatusFilter, number> {
  const base = entries.filter((entry) => matchesOthers(entry, filters));
  const count = (status: StatusFilter) => base.filter((entry) => matchesStatus(entry, status)).length;
  return { all: base.length, completed: count("completed"), pending: count("pending"), sinTasa: count("sinTasa"), manual: count("manual") };
}

export function registroTotals(entries: Pick<RegistroEntry, "status" | "facturadoGyd" | "invertidoGyd" | "retornoGyd">[]) {
  return entries.reduce(
    (totals, entry) =>
      entry.status === "completed"
        ? {
            facturado: totals.facturado + (entry.facturadoGyd ?? 0),
            invertido: totals.invertido + (entry.invertidoGyd ?? 0),
            retorno: totals.retorno + (entry.retornoGyd ?? 0),
            ops: totals.ops + 1,
          }
        : totals,
    { facturado: 0, invertido: 0, retorno: 0, ops: 0 },
  );
}

export function serviceOptions(entries: Pick<RegistroEntry, "service">[]): string[] {
  return [...new Set(entries.map((entry) => entry.service))];
}
