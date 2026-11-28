import type { SupabaseClient } from "@supabase/supabase-js";
import { validateRange, type DateRange, type RangeError } from "./periods";
import { mapFinancialClose, type FinancialClose, type FinancialCloseRpc } from "./read-model";

export type FinancialCloseResult =
  | { ok: true; data: FinancialClose }
  | { ok: false; error: RangeError | "load_failed" };

/** Reads the financial close for `range` (Guyana business days) through
 *  `crm_cierre_financiero`. Never throws: an invalid range is refused
 *  before the call, and a database failure is reported, not raised, so
 *  the page can show a message instead of crashing. */
export async function loadFinancialClose(
  db: SupabaseClient,
  range: DateRange,
): Promise<FinancialCloseResult> {
  const invalid = validateRange(range);
  if (invalid) return { ok: false, error: invalid };

  try {
    const { data, error } = await db.rpc("crm_cierre_financiero", {
      p_desde: range.desde,
      p_hasta: range.hasta,
    });
    if (error || !data) {
      if (error) console.error("[financial-close] crm_cierre_financiero failed:", error);
      return { ok: false, error: "load_failed" };
    }
    return { ok: true, data: mapFinancialClose(data as FinancialCloseRpc) };
  } catch (cause) {
    console.error("[financial-close] crm_cierre_financiero threw:", cause);
    return { ok: false, error: "load_failed" };
  }
}
