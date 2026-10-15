// Read model of the CUP inventory block in the delivery panel (phase 3). Pure: no I/O.
// The RPC crm_inventario_cup_operacion (migration 241) returns snake_case jsonb; this maps it and builds the display lines.
import { formatCup, formatRate } from "./format";

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

/** Before completion: an estimate of where the CUP will leave from. */
export interface CupPanelPlan {
  state: "plan";
  estimate: true;
  cubaDay: string | null;
  totalCup: number;
  plannedCup: number;
  missingCup: number;
  effectiveRate: number | null;
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
      beneficiaries,
    };
  }
  return null;
}

export interface PlanBeneficiaryRow {
  key: string;
  position: number;
  /** null when the beneficiary has no name: the caller writes "Beneficiario N". */
  beneficiary: string | null;
  amountText: string;
}

export interface PlanCardGroup {
  key: string;
  name: string;
  /** Last 4 digits only, never a full number. */
  last4: string | null;
  totalText: string;
  rows: PlanBeneficiaryRow[];
}

export interface PlanGrouped {
  /** Cards in order of first appearance in the plan (= priority order). */
  cards: PlanCardGroup[];
  /** One entry per beneficiary with CUP no card can take today. */
  shortages: PlanBeneficiaryRow[];
}

/** The plan grouped by card: card total, and one row per beneficiary (two lots of one card are one row). */
export function groupPlanByCard(plan: CupPanelPlan): PlanGrouped {
  const byCard = new Map<string, { name: string; last4: string | null; total: number; rows: Map<string, { row: PlanBeneficiaryRow; amount: number }> }>();
  const shortages: PlanBeneficiaryRow[] = [];
  for (const b of plan.beneficiaries) {
    const bKey = b.beneficiaryId || String(b.position);
    for (const l of b.lines) {
      let card = byCard.get(l.cardId);
      if (!card) {
        card = { name: l.cardName, last4: l.last4, total: 0, rows: new Map() };
        byCard.set(l.cardId, card);
      }
      card.total += l.amountCup;
      const prev = card.rows.get(bKey);
      if (prev) prev.amount += l.amountCup;
      else card.rows.set(bKey, { row: { key: `${l.cardId}:${bKey}`, position: b.position, beneficiary: b.name, amountText: "" }, amount: l.amountCup });
    }
    if (b.missingCup > 0) {
      shortages.push({ key: `${bKey}:missing`, position: b.position, beneficiary: b.name, amountText: formatCup(b.missingCup) });
    }
  }
  const cards = [...byCard].map(([key, c]) => ({
    key,
    name: c.name,
    last4: c.last4,
    totalText: formatCup(c.total),
    rows: [...c.rows.values()].map(({ row, amount }) => ({ ...row, amountText: formatCup(amount) })),
  }));
  return { cards, shortages };
}

export interface UsedLotRow {
  key: string;
  rateText: string;
  amountText: string;
}

export interface UsedCardGroup {
  key: string;
  name: string;
  last4: string | null;
  totalText: string;
  rows: UsedLotRow[];
}

/** After completion: consumptions grouped by card (first appearance), card total, one row per lot rate. */
export function groupConsumptionsByCard(done: CupPanelCompleted): UsedCardGroup[] {
  const byCard = new Map<string, { name: string; last4: string | null; total: number; rows: UsedLotRow[] }>();
  done.lines.forEach((l, i) => {
    let card = byCard.get(l.cardId);
    if (!card) {
      card = { name: l.cardName, last4: l.last4, total: 0, rows: [] };
      byCard.set(l.cardId, card);
    }
    card.total += l.amountCup;
    card.rows.push({ key: `${l.lotId}:${i}`, rateText: formatRate(l.lotRate), amountText: formatCup(l.amountCup) });
  });
  return [...byCard].map(([key, c]) => ({ key, name: c.name, last4: c.last4, totalText: formatCup(c.total), rows: c.rows }));
}

/** What the block shows for a read: nothing for the empty states (and when there is nothing to list). */
export function visibleCupPanel(read: CupPanelRead | null): CupPanelPlan | CupPanelCompleted | null {
  if (!read) return null;
  if (read.state === "plan") return read.beneficiaries.length > 0 ? read : null;
  if (read.state === "completed") return read.lines.length > 0 ? read : null;
  return null;
}
