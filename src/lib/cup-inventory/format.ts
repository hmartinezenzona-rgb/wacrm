// Display and input helpers of the CUP inventory page. Pure: no I/O.
import { formatNumber } from "@/lib/format-number";

/** CUP amount as the rest of the app writes figures ("500 000"); decimals only when there are some. */
export function formatCup(value: number): string {
  return formatNumber(value, { maximumFractionDigits: 2 });
}

/** CUP per USDT, up to two decimals. */
export function formatRate(value: number): string {
  return formatNumber(value, { maximumFractionDigits: 2 });
}

const GROUPED = (sep: string) => new RegExp(`^\\d{1,3}(\\${sep}\\d{3})+$`);

/**
 * Reads a number typed by the owner. Blanks are ignored; with both separators the last one is the decimal mark
 * ("1.157.712,40", "1,157,712.40"); a lone "." followed by exactly three digits groups thousands ("500.000", the Spanish
 * habit) and any other lone "." is a decimal; a lone "," is a decimal ("960,5"). Returns null unless the result is a finite
 * number > 0.
 */
export function parseCupNumber(text: string): number | null {
  const raw = text.replace(/\s/g, "");
  if (!/^[\d.,]+$/.test(raw)) return null;

  const dots = (raw.match(/\./g) ?? []).length;
  const commas = (raw.match(/,/g) ?? []).length;
  let normalized: string;

  if (dots > 0 && commas > 0) {
    const decimal = raw.lastIndexOf(".") > raw.lastIndexOf(",") ? "." : ",";
    const group = decimal === "." ? "," : ".";
    const [integer, fraction, ...rest] = raw.split(decimal);
    if (rest.length > 0 || !GROUPED(group).test(integer) || !/^\d+$/.test(fraction)) return null;
    normalized = `${integer.split(group).join("")}.${fraction}`;
  } else if (dots > 0) {
    if (dots > 1 || GROUPED(".").test(raw)) {
      if (!GROUPED(".").test(raw)) return null;
      normalized = raw.split(".").join("");
    } else {
      normalized = raw;
    }
  } else if (commas > 0) {
    if (commas > 1) return null;
    normalized = raw.replace(",", ".");
  } else {
    normalized = raw;
  }

  if (!/^\d+(\.\d+)?$/.test(normalized)) return null;
  const value = Number(normalized);
  return Number.isFinite(value) && value > 0 ? value : null;
}

export interface PriorityPatch {
  id: string;
  priority: number;
}

/**
 * Moves one card a place up or down in the priority order. The cards are ordered by (priority, given order), the move is
 * applied and the order is renumbered 1..n, so ties and gaps are repaired as a side effect. Returns only the cards whose
 * priority changes, in their new order: the caller saves exactly those.
 */
export function moveCardPriorities(
  cards: ReadonlyArray<{ id: string; priority: number }>,
  id: string,
  direction: "up" | "down",
): PriorityPatch[] {
  const ordered = cards
    .map((card, index) => ({ card, index }))
    .sort((a, b) => a.card.priority - b.card.priority || a.index - b.index)
    .map(({ card }) => card);

  const from = ordered.findIndex((card) => card.id === id);
  const to = direction === "up" ? from - 1 : from + 1;
  if (from < 0 || to < 0 || to >= ordered.length) return [];

  [ordered[from], ordered[to]] = [ordered[to], ordered[from]];
  return ordered
    .map((card, index) => ({ id: card.id, priority: index + 1, previous: card.priority }))
    .filter((card) => card.priority !== card.previous)
    .map(({ id: cardId, priority }) => ({ id: cardId, priority }));
}
