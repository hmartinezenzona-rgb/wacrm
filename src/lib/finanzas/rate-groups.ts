// The global rates of the calculator and how "Tasas actuales" groups them. Adding a rate to the screen is one line in
// RATE_GROUPS; a rate that is in RATE_FIELDS but in no group still shows, in a last group (see `ungroupedRates`).

import type { CalculatorRates } from "@/lib/calculator/ledger-read-model";

export type RateKey =
  | "cup_global_rate" | "usdt_buy_gyd" | "usdt_sell_gyd" | "usdt_sell_cup" | "zelle_sell_gyd"
  | "zelle_sell_gyd_1000" | "zelle_sell_gyd_2000" | "efectivo_usd_gyd" | "recarga_costo_usdt"
  | "saldo_costo_usdt" | "recarga_costo_usdt_500";

export interface RateField {
  key: RateKey;
  label: string;
  field: keyof CalculatorRates;
}

// Every global rate, in the order the rate editor has always listed them.
export const RATE_FIELDS: ReadonlyArray<RateField> = [
  { key: "cup_global_rate", label: "Tarifa CUP global", field: "cupGlobalRate" },
  { key: "usdt_buy_gyd", label: "Compra USDT (GYD)", field: "usdtBuyGyd" },
  { key: "usdt_sell_gyd", label: "Venta USDT (GYD)", field: "usdtSellGyd" },
  { key: "usdt_sell_cup", label: "Venta USDT (CUP)", field: "usdtSellCup" },
  { key: "zelle_sell_gyd", label: "Zelle desde 50 USD", field: "zelleSellGyd" },
  { key: "zelle_sell_gyd_1000", label: "Zelle desde 1,000 USD", field: "zelleSellGyd1000" },
  { key: "zelle_sell_gyd_2000", label: "Zelle desde 2,000 USD", field: "zelleSellGyd2000" },
  { key: "efectivo_usd_gyd", label: "Efectivo USD (GYD por dólar)", field: "efectivoUsdGyd" },
  { key: "recarga_costo_usdt", label: "Costo recarga desde 600 (USDT)", field: "recargaCostoUsdt" },
  { key: "saldo_costo_usdt", label: "Costo saldo (USDT)", field: "saldoCostoUsdt" },
  { key: "recarga_costo_usdt_500", label: "Costo recarga desde 500 (USDT)", field: "recargaCostoUsdt500" },
];

export function rateValueOf(rates: CalculatorRates | null, key: RateKey, fields: ReadonlyArray<RateField> = RATE_FIELDS): number | null {
  const field = fields.find((f) => f.key === key)?.field;
  return field ? ((rates?.[field] as number | null | undefined) ?? null) : null;
}

export interface GroupedRate {
  key: RateKey;
  /** Short name, read under the group's title. */
  label: string;
  /** Written after the value ("GYD", "CUP", "USDT"); none for a bare ratio. */
  unit?: string;
  /** A line under the label for a rate that also drives other services. */
  note?: string;
}

export interface RateGroup {
  id: string;
  title: string;
  rates: GroupedRate[];
  /** The read-only ARQ USD -> MXN rate is drawn at the end of this group. */
  withArq?: boolean;
}

export const RATE_GROUPS: ReadonlyArray<RateGroup> = [
  {
    id: "usdt",
    title: "USDT",
    rates: [
      { key: "usdt_buy_gyd", label: "Compra", unit: "GYD" },
      { key: "usdt_sell_gyd", label: "Venta", unit: "GYD", note: "también Clásica, Tropical y México" },
      { key: "usdt_sell_cup", label: "Venta en CUP", unit: "CUP" },
    ],
  },
  {
    id: "zelle",
    title: "Zelle · GYD por dólar",
    rates: [
      { key: "zelle_sell_gyd", label: "Desde 50 USD", unit: "GYD" },
      { key: "zelle_sell_gyd_1000", label: "Desde 1,000 USD", unit: "GYD" },
      { key: "zelle_sell_gyd_2000", label: "Desde 2,000 USD", unit: "GYD" },
    ],
  },
  {
    id: "recargas",
    title: "Recargas y saldo · costo",
    rates: [
      { key: "recarga_costo_usdt_500", label: "Recarga desde 500", unit: "USDT" },
      { key: "recarga_costo_usdt", label: "Recarga desde 600", unit: "USDT" },
      { key: "saldo_costo_usdt", label: "Saldo móvil", unit: "USDT" },
    ],
  },
  {
    id: "cup",
    title: "CUP, efectivo y México",
    withArq: true,
    rates: [
      { key: "cup_global_rate", label: "Tarifa CUP global" },
      { key: "efectivo_usd_gyd", label: "Efectivo USD", unit: "GYD" },
    ],
  },
];

/** Rates of `RATE_FIELDS` that no group lists. */
export function ungroupedRates(groups: ReadonlyArray<RateGroup>, fields: ReadonlyArray<RateField> = RATE_FIELDS): RateField[] {
  const placed = new Set(groups.flatMap((group) => group.rates.map((rate) => rate.key)));
  return fields.filter((field) => !placed.has(field.key));
}
