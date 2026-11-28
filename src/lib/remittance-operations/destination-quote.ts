import { deriveAmountFromDeposit, type CalculatorAutoCompletionService, type CalculatorDocumentRates } from "@/lib/calculator/document-rates";
import type { OperationService } from "./services";

// What the correction form shows as the destination amount while the person edits the service or the deposit. The
// stored value is always the one the database computes (crm_calcular_monto_destino); this only previews it, with the
// TypeScript mirror of that calculation (document-rates.ts), so keep them in step.

interface ServiceQuote {
  /** Currency the destination amount is delivered in. */
  currency: "USD" | "CUP";
  /** The calculation service of document-rates.ts that prices a deposit for it. */
  calc: CalculatorAutoCompletionService;
  /** Smallest GYD deposit the service takes (México: 13,000 GYD); below it there is no quote. */
  minimumGyd?: number;
}

const SERVICE_QUOTES: Partial<Record<OperationService, ServiceQuote>> = {
  cuban_card: { currency: "CUP", calc: "CUP" },
  zelle: { currency: "USD", calc: "ZELLE" },
  clasica: { currency: "USD", calc: "CLASICA" },
  tropical: { currency: "USD", calc: "TROPICAL" },
  efectivo_usd: { currency: "USD", calc: "EFECTIVO" },
  // México sells whole USD at the single USD sale rate, like clasica (migration pricing: 260 GYD per USD).
  mexico: { currency: "USD", calc: "CLASICA", minimumGyd: 13000 },
};

/** The destination currency a service delivers in, or `null` when the service has no destination quote (recarga,
 *  saldo, combo, visa) or no service is chosen. */
export function destinationCurrencyOf(service: string): "USD" | "CUP" | null {
  return SERVICE_QUOTES[service as OperationService]?.currency ?? null;
}

/** The destination amount a deposit buys at the service's rate (CUP rounded, USD rails rounded DOWN), or `null` when
 *  the service has no quote, the deposit is not a positive number, or the rate is not set. */
export function previewDestinationAmount(
  service: string,
  depositGyd: number,
  rates: CalculatorDocumentRates | null,
): number | null {
  const quote = SERVICE_QUOTES[service as OperationService];
  if (!quote || !rates) return null;
  if (quote.minimumGyd !== undefined && !(depositGyd >= quote.minimumGyd)) return null;
  try {
    const amount = deriveAmountFromDeposit(quote.calc, depositGyd, rates);
    if (amount === null) return null;
    return quote.currency === "CUP" ? Math.round(amount) : amount;
  } catch {
    return null;
  }
}
