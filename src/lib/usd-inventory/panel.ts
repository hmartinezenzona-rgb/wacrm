// Read model of the USD inventory block in the delivery panel. Pure: no I/O.
// `crm_inventario_usd_operacion` (migration 356) returns snake_case jsonb; this maps it. Before completion it is an estimate
// (which card and lot each service's USD will leave from, and whether the balance is short); after it, what really left.
import type { UsdService } from "./read-model";

export interface UsdPanelLine {
  cardId: string;
  cardName: string;
  last4: string | null;
  lotId: string;
  amountUsd: number;
  /** USD received per USDT paid on the lot (1.05 = a 5% lot). */
  usdPerUsdt: number;
}

export interface UsdPanelServicePlan {
  service: UsdService;
  neededUsd: number;
  plannedUsd: number;
  missingUsd: number;
  blocked: boolean;
  investedUsdt: number;
  lines: UsdPanelLine[];
}

export interface UsdPanelPlan {
  state: "plan";
  estimate: true;
  cubaMonth: string | null;
  /** Some service lacks balance: the server refuses to complete. */
  blocked: boolean;
  services: UsdPanelServicePlan[];
}

export interface UsdPanelCompleted {
  state: "completed";
  estimate: false;
  consumedUsd: number;
  investedUsdt: number;
  costGyd: number | null;
  shortfallUsd: number;
  lines: Array<UsdPanelLine & { service: UsdService }>;
}

export type UsdPanelEmptyState = "unavailable" | "not_usd" | "no_inventory" | "no_amounts";
export interface UsdPanelEmpty {
  state: UsdPanelEmptyState;
}

export type UsdPanelRead = UsdPanelPlan | UsdPanelCompleted | UsdPanelEmpty;

type Row = Record<string, unknown>;

const num = (value: unknown): number => Number(value ?? 0);

function mapLine(row: Row): UsdPanelLine {
  return {
    cardId: String(row.card_id),
    cardName: String(row.card_name),
    last4: (row.last4 as string | null | undefined) ?? null,
    lotId: String(row.lot_id),
    amountUsd: num(row.amount_usd),
    usdPerUsdt: num(row.usd_per_usdt),
  };
}

const EMPTY_STATES: readonly string[] = ["unavailable", "not_usd", "no_inventory", "no_amounts"];

/** Null when the payload is not one the panel knows (the caller answers 502 / renders nothing). */
export function mapUsdPanel(payload: unknown): UsdPanelRead | null {
  if (typeof payload !== "object" || payload === null) return null;
  const body = payload as Row;
  const state = body.state;

  if (typeof state === "string" && EMPTY_STATES.includes(state)) return { state: state as UsdPanelEmptyState };

  if (state === "plan") {
    return {
      state: "plan",
      estimate: true,
      cubaMonth: (body.cuba_month as string | null | undefined) ?? null,
      blocked: body.blocked === true,
      services: Array.isArray(body.services)
        ? (body.services as Row[]).map((service) => ({
            service: service.service as UsdService,
            neededUsd: num(service.needed_usd),
            plannedUsd: num(service.planned_usd),
            missingUsd: num(service.missing_usd),
            blocked: service.blocked === true,
            investedUsdt: num(service.invested_usdt),
            lines: Array.isArray(service.lines) ? (service.lines as Row[]).map(mapLine) : [],
          }))
        : [],
    };
  }

  if (state === "completed") {
    return {
      state: "completed",
      estimate: false,
      consumedUsd: num(body.consumed_usd),
      investedUsdt: num(body.invested_usdt),
      costGyd: body.cost_gyd === null || body.cost_gyd === undefined ? null : num(body.cost_gyd),
      shortfallUsd: num(body.shortfall_usd),
      lines: Array.isArray(body.lines) ? (body.lines as Row[]).map((row) => ({ ...mapLine(row), service: row.service as UsdService })) : [],
    };
  }

  return null;
}

/** The plan or the completed read; the empty states render nothing. */
export function visibleUsdPanel(read: UsdPanelRead): UsdPanelPlan | UsdPanelCompleted | null {
  return read.state === "plan" || read.state === "completed" ? read : null;
}

export function isUsdPlanBlocked(read: UsdPanelRead | null): boolean {
  return read !== null && read.state === "plan" && read.blocked;
}
