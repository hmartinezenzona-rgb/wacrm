// One shape for the CUP cards and the Clásica / Tropical (USD) cards, so the inventory page can list, filter and total them
// together. Pure: no I/O. The two read models stay the source of truth; this only normalizes them.
import type { InventoryCard } from "@/lib/cup-inventory/read-model";
import type { UsdCard, UsdService } from "@/lib/usd-inventory/read-model";

export type CardService = "CUP" | UsdService;
export type CardUnit = "CUP" | "USD";
export type CardFilter = "all" | CardService;

export const SERVICE_ORDER: readonly CardService[] = ["CUP", "CLASICA", "TROPICAL"];

export interface UnifiedLot {
  id: string;
  loadedAt: string;
  /** Bought: CUP for a CUP card, USD for a USD card. */
  amount: number;
  remaining: number;
  /** USDT paid for the lot (CUP lots: derived from the rate). */
  usdtPaid: number;
  /** CUP per USDT; CUP lots only. */
  rateCupPerUsdt: number | null;
  /** USD received per USDT; USD lots only (1.05 = 5% discount). */
  usdPerUsdt: number | null;
  note: string | null;
  editable: boolean;
  exhausted: boolean;
  adjusted: boolean;
}

export interface UnifiedMovement {
  id: string;
  consumedAt: string;
  amount: number;
  /** CUP per USDT (CUP) or USD per USDT (USD) of the lot it came from. */
  lotRate: number;
  kind: "operacion" | "manual" | "ajuste";
  source: string | null;
  customerName: string | null;
  reason: string | null;
}

export interface UnifiedCard {
  key: string;
  service: CardService;
  unit: CardUnit;
  id: string;
  name: string;
  last4: string | null;
  priority: number;
  active: boolean;
  balance: number;
  /** Daily limit (CUP) or monthly limit (USD). Informational for USD. */
  limit: number;
  used: number;
  remaining: number;
  period: "day" | "month";
  lots: UnifiedLot[];
  movements: UnifiedMovement[];
}

function fromCup(card: InventoryCard): UnifiedCard {
  return {
    key: `CUP:${card.id}`,
    service: "CUP",
    unit: "CUP",
    id: card.id,
    name: card.name,
    last4: card.last4,
    priority: card.priority,
    active: card.active,
    balance: card.balanceCup,
    limit: card.dailyLimitCup,
    used: card.usedTodayCup,
    remaining: card.remainingLimitTodayCup,
    period: "day",
    lots: card.lots.map((lot) => ({
      id: lot.id,
      loadedAt: lot.loadedAt,
      amount: lot.amountCup,
      remaining: lot.remainingCup,
      usdtPaid: lot.rateCupPerUsdt > 0 ? lot.amountCup / lot.rateCupPerUsdt : 0,
      rateCupPerUsdt: lot.rateCupPerUsdt,
      usdPerUsdt: null,
      note: lot.note,
      editable: lot.editable,
      exhausted: lot.exhausted,
      adjusted: lot.adjusted,
    })),
    movements: card.consumptionsToday.map((move) => ({
      id: move.id,
      consumedAt: move.consumedAt,
      amount: move.amountCup,
      lotRate: move.lotRateCupPerUsdt,
      kind: move.kind,
      source: move.source,
      customerName: move.customerName,
      reason: move.reason,
    })),
  };
}

function fromUsd(card: UsdCard): UnifiedCard {
  return {
    key: `${card.service}:${card.id}`,
    service: card.service,
    unit: "USD",
    id: card.id,
    name: card.name,
    last4: card.last4,
    priority: card.priority,
    active: card.active,
    balance: card.balanceUsd,
    limit: card.monthlyLimitUsd,
    used: card.usedThisMonthUsd,
    remaining: card.remainingMonthUsd,
    period: "month",
    lots: card.lots.map((lot) => ({
      id: lot.id,
      loadedAt: lot.loadedAt,
      amount: lot.amountUsd,
      remaining: lot.remainingUsd,
      usdtPaid: lot.usdtPaid,
      rateCupPerUsdt: null,
      usdPerUsdt: lot.usdPerUsdt,
      note: lot.note,
      editable: lot.editable,
      exhausted: lot.exhausted,
      adjusted: lot.adjusted,
    })),
    movements: card.consumptionsMonth.map((move) => ({
      id: move.id,
      consumedAt: move.consumedAt,
      amount: move.amountUsd,
      lotRate: move.lotUsdPerUsdt,
      kind: move.kind,
      source: move.source,
      customerName: move.customerName,
      reason: move.reason,
    })),
  };
}

/** CUP cards first, then Clásica, then Tropical; each list keeps the order its report gave (priority). */
export function unifyCards(cup: InventoryCard[], usd: UsdCard[]): UnifiedCard[] {
  return [
    ...cup.map(fromCup),
    ...usd.filter((card) => card.service === "CLASICA").map(fromUsd),
    ...usd.filter((card) => card.service === "TROPICAL").map(fromUsd),
  ];
}

export interface ServiceTotal {
  service: CardService;
  unit: CardUnit;
  cards: number;
  balance: number;
  /** No balance at all (also when the service has no card yet): the strip paints it red. */
  empty: boolean;
}

/** One total per service (always all three), counting active cards only. */
export function serviceTotals(cards: UnifiedCard[]): ServiceTotal[] {
  return SERVICE_ORDER.map((service) => {
    const own = cards.filter((card) => card.service === service && card.active);
    const balance = own.reduce((sum, card) => sum + card.balance, 0);
    return { service, unit: service === "CUP" ? "CUP" : "USD", cards: own.length, balance, empty: balance <= 0 };
  });
}

export function filterCards(cards: UnifiedCard[], filter: CardFilter): UnifiedCard[] {
  return filter === "all" ? cards : cards.filter((card) => card.service === filter);
}

/** Share of the limit already used, 0..100. */
export function limitPercent(card: Pick<UnifiedCard, "used" | "limit">): number {
  if (card.limit <= 0) return 0;
  return Math.min(100, Math.max(0, (card.used / card.limit) * 100));
}

/** What one USD of a lot costs in GYD: the current USDT buy rate divided by the lot's USD per USDT. */
export function costPerUsd(usdtBuyGyd: number | null, usdPerUsdt: number | null): number | null {
  if (usdtBuyGyd === null || usdPerUsdt === null || usdPerUsdt <= 0) return null;
  return usdtBuyGyd / usdPerUsdt;
}

/** What the owner earns on each USD sold at the current price. */
export function profitPerUsd(usdtSellGyd: number | null, cost: number | null): number | null {
  if (usdtSellGyd === null || cost === null) return null;
  return usdtSellGyd - cost;
}
