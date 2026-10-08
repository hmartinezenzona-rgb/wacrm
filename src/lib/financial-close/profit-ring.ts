import type { CloseAggregate } from "./read-model";

export interface ProfitRingRow {
  service: string;
  profit: number;
  /** Fraction (0..1) of the sum of positive profits; null when it has no meaning (negative service, or no ring). */
  share: number | null;
  /** Whether the service gets a slice in the ring (positive profit and a ring to draw). */
  slice: boolean;
}

export interface ProfitRing {
  /** Every service, profit descending. */
  rows: ProfitRingRow[];
  /** Net profit of the period (negative services included). */
  totalProfit: number;
  /** Sum of the positive profits: the base of every percentage. */
  positiveTotal: number;
  /** A ring is only drawn when the net profit is positive. */
  hasRing: boolean;
}

/**
 * Profit by service as ring slices. A negative profit cannot be a slice, so it
 * stays out of the ring and out of the percentage base; zero profit is listed
 * without a slice. With a net profit <= 0 there is nothing to proportion.
 */
export function buildProfitRing(byService: (CloseAggregate & { service: string })[]): ProfitRing {
  const sorted = [...byService].sort((a, b) => b.retornoGyd - a.retornoGyd);
  const totalProfit = sorted.reduce((sum, s) => sum + s.retornoGyd, 0);
  const positiveTotal = sorted.reduce((sum, s) => sum + Math.max(s.retornoGyd, 0), 0);
  const hasRing = totalProfit > 0;

  const rows = sorted.map((s): ProfitRingRow => {
    const profit = s.retornoGyd;
    if (!hasRing || profit < 0) return { service: s.service, profit, share: null, slice: false };
    return { service: s.service, profit, share: profit / positiveTotal, slice: profit > 0 };
  });

  return { rows, totalProfit, positiveTotal, hasRing };
}
