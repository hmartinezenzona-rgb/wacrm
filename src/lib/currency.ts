/**
 * Currency — single source of truth for deal-value formatting and
 * the currency picker options.
 *
 * Before this module, ~6 components each defined their own
 * `Intl.NumberFormat(..., { currency: "USD" })` helper with USD
 * baked in. The default currency is now configurable per account
 * (accounts.default_currency, migration 021), so every formatter
 * takes a currency and falls back to DEFAULT_CURRENCY only when
 * nothing is known.
 */

/**
 * Locale every money string is formatted in.
 *
 * These formatters used to pass `undefined`, which means "whatever
 * locale this particular browser is set to". Two people looking at the
 * same board saw the same amount written differently — "USD 1,618,310"
 * for one, "1.618.310 US$" for another — with the separators and the
 * position of the currency marker both moving. In a product whose whole
 * job is moving money, the numbers have to read the same for everyone.
 *
 * en-US matches what the rest of the app already hard-codes (Resumen's
 * `toLocaleString("en-US")`, the dashboard's compact figures). It
 * changes nothing for GYD or CUP: neither has a symbol in any locale,
 * so both stay "GYD 25,000" / "CUP 1,200" as before.
 */
const FORMATTING_LOCALE = "en-US";

/** App-wide fallback when no account/deal currency is available. */
export const DEFAULT_CURRENCY = "USD";

export interface CurrencyOption {
  /** ISO-4217 code, e.g. "USD". Stored verbatim in the DB. */
  code: string;
  /** Human label for the dropdown, e.g. "US Dollar". */
  label: string;
  /** Symbol for compact display, e.g. "$". */
  symbol: string;
}

/**
 * The currencies offered in pickers. Codes must be valid ISO-4217 so
 * `Intl.NumberFormat` renders the right symbol/grouping. Extend this
 * list to offer more — nothing else needs to change.
 */
export const CURRENCIES: CurrencyOption[] = [
  // Las tres del negocio van primero: son las unicas que Remesas Core
  // reconoce (`Currency` en domain/enums.py — GYD lo que deposita el
  // cliente, CUP lo que recibe el beneficiario, USD la entrega en
  // dolares). GYD y CUP faltaban aqui, asi que la cuenta no podia
  // configurarse en la moneda con la que realmente opera y los totales
  // del tablero rotulaban en USD una suma de remesas en GYD.
  //
  // Su "simbolo" es el propio codigo a proposito: ni GYD ni CUP tienen
  // simbolo en ningun locale, asi que `Intl` ya las escribe "GYD 25,000".
  // Ponerlo aqui hace que la version compacta diga "GYD 25.0k" y no
  // invente un "$" que se confundiria con el dolar.
  { code: "GYD", label: "Guyanese Dollar", symbol: "GYD " },
  { code: "CUP", label: "Cuban Peso", symbol: "CUP " },
  { code: "USD", label: "US Dollar", symbol: "$" },
  { code: "EUR", label: "Euro", symbol: "€" },
  { code: "GBP", label: "British Pound", symbol: "£" },
  { code: "INR", label: "Indian Rupee", symbol: "₹" },
  { code: "AUD", label: "Australian Dollar", symbol: "A$" },
  { code: "CAD", label: "Canadian Dollar", symbol: "C$" },
  { code: "BRL", label: "Brazilian Real", symbol: "R$" },
  { code: "JPY", label: "Japanese Yen", symbol: "¥" },
  { code: "CNY", label: "Chinese Yuan", symbol: "¥" },
  { code: "AED", label: "UAE Dirham", symbol: "د.إ" },
  { code: "ZAR", label: "South African Rand", symbol: "R" },
  { code: "NGN", label: "Nigerian Naira", symbol: "₦" },
  { code: "SGD", label: "Singapore Dollar", symbol: "S$" },
  { code: "MXN", label: "Mexican Peso", symbol: "$" },
];

/**
 * Format a deal value as a currency string. Whole-number output
 * (no minor units) — deal values are tracked to the dollar across
 * the app. `currency` defaults to USD so callers with nothing better
 * stay safe, but pass the account/deal currency wherever known.
 *
 * Total by design: `Intl.NumberFormat` throws a RangeError on a
 * structurally invalid currency code, and `deals.currency` carries
 * NO DB CHECK (only `accounts.default_currency` does), so legacy
 * rows, imports, or hand-edited data can hold malformed values like
 * "United States". We never let that crash a render — on a bad code
 * we fall back to "CODE 1,234".
 */
export function formatCurrency(
  value: number,
  currency: string = DEFAULT_CURRENCY,
): string {
  const code = (currency || DEFAULT_CURRENCY).trim();
  const amount = Number(value) || 0;
  try {
    return new Intl.NumberFormat(FORMATTING_LOCALE, {
      style: "currency",
      currency: code,
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    }).format(amount);
  } catch {
    // Invalid ISO code — show the raw code + grouped number so the
    // value is still legible instead of throwing.
    return `${code} ${new Intl.NumberFormat(FORMATTING_LOCALE, {
      maximumFractionDigits: 0,
    }).format(amount)}`;
  }
}

/**
 * Compact currency for tight spaces (donut center, legend rows):
 * "$1.2M" / "€34.5k" / "₹900". Uses the currency's symbol from
 * CURRENCIES, falling back to the code when we don't carry a symbol.
 */
export function formatCurrencyShort(
  value: number,
  currency: string = DEFAULT_CURRENCY,
): string {
  const code = currency || DEFAULT_CURRENCY;
  const symbol = CURRENCIES.find((c) => c.code === code)?.symbol ?? `${code} `;
  return `${symbol}${formatCompactNumber(value)}`;
}

/**
 * Compact number for tight spaces (chart tiles, legends): 1_234 → "1.2k",
 * 1_200_000 → "1.2M", 900 → "900". The unit-less core shared with
 * {@link formatCurrencyShort}.
 */
export function formatCompactNumber(value: number): string {
  const v = Number(value || 0);
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}k`;
  return v.toFixed(0);
}
