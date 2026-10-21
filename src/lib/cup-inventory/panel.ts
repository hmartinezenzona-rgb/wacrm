// Read model of the CUP inventory block in the delivery panel (phase 3). Pure: no I/O.
// The RPC crm_inventario_cup_operacion (migration 241) returns snake_case jsonb; this maps it and builds the display lines.
import { formatCup } from "./format";

export interface CupPanelLine {
  cardId: string;
  cardName: string;
  last4: string | null;
  lotId: string;
  amountCup: number;
  lotRate: number;
}

export interface CupPanelBeneficiary {
  beneficiaryId: string;
  position: number;
  name: string | null;
  amountCup: number;
  missingCup: number;
  lines: CupPanelLine[];
}

/** An active sending card offered by the picker (migration 257): current balance and what is left of today's limit. */
export interface CupPickerCard {
  id: string;
  name: string;
  last4: string | null;
  balanceCup: number;
  remainingLimitTodayCup: number;
}

/** Before completion: an estimate of where the CUP will leave from. */
export interface CupPanelPlan {
  state: "plan";
  estimate: true;
  cubaDay: string | null;
  totalCup: number;
  plannedCup: number;
  missingCup: number;
  effectiveRate: number | null;
  /** The card the plan starts from (the operator's choice); null = by priority. */
  sourceCardId: string | null;
  /** The account's active cards for the picker, by priority. */
  cards: CupPickerCard[];
  beneficiaries: CupPanelBeneficiary[];
}

/** After completion: what really left. */
export interface CupPanelCompleted {
  state: "completed";
  estimate: false;
  consumedCup: number;
  cupRate: number | null;
  lines: CupPanelLine[];
}

export type CupPanelEmptyState = "not_cup" | "no_inventory" | "no_amounts" | "unavailable";
export interface CupPanelEmpty {
  state: CupPanelEmptyState;
}

export type CupPanelRead = CupPanelPlan | CupPanelCompleted | CupPanelEmpty;

const EMPTY_STATES: ReadonlyArray<string> = ["not_cup", "no_inventory", "no_amounts", "unavailable"];

type Raw = Record<string, unknown>;

function isRecord(value: unknown): value is Raw {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function num(value: unknown): number | null {
  const n = typeof value === "string" ? Number(value) : value;
  return typeof n === "number" && Number.isFinite(n) ? n : null;
}

function str(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

function mapLine(raw: unknown): CupPanelLine | null {
  if (!isRecord(raw)) return null;
  const amountCup = num(raw.amount_cup);
  const lotRate = num(raw.lot_rate);
  const cardName = str(raw.card_name);
  if (amountCup === null || lotRate === null || cardName === null) return null;
  return {
    cardId: str(raw.card_id) ?? cardName,
    cardName,
    last4: str(raw.last4),
    lotId: str(raw.lot_id) ?? "",
    amountCup,
    lotRate,
  };
}

function mapLines(raw: unknown): CupPanelLine[] | null {
  if (!Array.isArray(raw)) return null;
  const lines = raw.map(mapLine);
  return lines.every((l): l is CupPanelLine => l !== null) ? (lines as CupPanelLine[]) : null;
}

function mapPickerCards(raw: unknown): CupPickerCard[] {
  if (!Array.isArray(raw)) return [];
  const cards: CupPickerCard[] = [];
  for (const c of raw) {
    if (!isRecord(c)) continue;
    const id = str(c.id);
    const name = str(c.name);
    const balanceCup = num(c.balance_cup);
    const remainingLimitTodayCup = num(c.remaining_limit_today_cup);
    if (id === null || name === null || balanceCup === null || remainingLimitTodayCup === null) continue;
    cards.push({ id, name, last4: str(c.last4), balanceCup, remainingLimitTodayCup });
  }
  return cards;
}

/** Maps the RPC/API payload; null when it is not a known shape (the caller then shows nothing). */
export function mapCupPanel(raw: unknown): CupPanelRead | null {
  if (!isRecord(raw)) return null;
  const state = raw.state;
  if (typeof state === "string" && EMPTY_STATES.includes(state)) return { state: state as CupPanelEmptyState };

  if (state === "completed") {
    const lines = mapLines(raw.lines);
    const consumedCup = num(raw.consumed_cup);
    if (!lines || consumedCup === null) return null;
    return { state: "completed", estimate: false, consumedCup, cupRate: num(raw.cup_rate), lines };
  }

  if (state === "plan") {
    if (!Array.isArray(raw.beneficiaries)) return null;
    const beneficiaries: CupPanelBeneficiary[] = [];
    for (const b of raw.beneficiaries) {
      if (!isRecord(b)) return null;
      const lines = mapLines(b.lines);
      const amountCup = num(b.amount_cup);
      const missingCup = num(b.missing_cup);
      if (!lines || amountCup === null || missingCup === null) return null;
      beneficiaries.push({
        beneficiaryId: str(b.beneficiary_id) ?? "",
        position: num(b.position) ?? beneficiaries.length + 1,
        name: str(b.name),
        amountCup,
        missingCup,
        lines,
      });
    }
    const totalCup = num(raw.total_cup);
    const plannedCup = num(raw.planned_cup);
    const missingCup = num(raw.missing_cup);
    if (totalCup === null || plannedCup === null || missingCup === null) return null;
    return {
      state: "plan",
      estimate: true,
      cubaDay: str(raw.cuba_day),
      totalCup,
      plannedCup,
      missingCup,
      effectiveRate: num(raw.effective_rate),
      sourceCardId: str(raw.source_card_id),
      cards: mapPickerCards(raw.cards),
      beneficiaries,
    };
  }
  return null;
}

/** One row of the block: a card and the CUP that leaves (or left) from it. */
export interface CupCardTotal {
  key: string;
  name: string;
  /** Last 4 digits only, never a full number. */
  last4: string | null;
  totalText: string;
}

export interface PlanGrouped {
  /** Cards in order of first appearance in the plan (= priority order). */
  cards: CupCardTotal[];
  /** CUP no card can take today, added up across beneficiaries; null when nothing is missing. */
  missingText: string | null;
}

function totalsByCard(lines: CupPanelLine[]): CupCardTotal[] {
  const byCard = new Map<string, { name: string; last4: string | null; total: number }>();
  for (const l of lines) {
    const card = byCard.get(l.cardId);
    if (card) card.total += l.amountCup;
    else byCard.set(l.cardId, { name: l.cardName, last4: l.last4, total: l.amountCup });
  }
  return [...byCard].map(([key, c]) => ({ key, name: c.name, last4: c.last4, totalText: formatCup(c.total) }));
}

/** The plan as one total per card, plus the CUP that is missing in all (a card may serve several beneficiaries). */
export function groupPlanByCard(plan: CupPanelPlan): PlanGrouped {
  const missing = plan.beneficiaries.reduce((sum, b) => sum + (b.missingCup > 0 ? b.missingCup : 0), 0);
  return {
    cards: totalsByCard(plan.beneficiaries.flatMap((b) => b.lines)),
    missingText: missing > 0 ? formatCup(missing) : null,
  };
}

/** After completion: what left from each card (first appearance), one total per card. */
export function groupConsumptionsByCard(done: CupPanelCompleted): CupCardTotal[] {
  return totalsByCard(done.lines);
}

/** What the block shows for a read: nothing for the empty states (and when there is nothing to list). */
export function visibleCupPanel(read: CupPanelRead | null): CupPanelPlan | CupPanelCompleted | null {
  if (!read) return null;
  if (read.state === "plan") return read.beneficiaries.length > 0 ? read : null;
  if (read.state === "completed") return read.lines.length > 0 ? read : null;
  return null;
}
