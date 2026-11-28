// ============================================================
// POST /api/calculator/entries/{entryId}/rates
//
// Lets an admin change the INVESTMENT rates a completed calculator entry
// was costed with -- `usdtBuyGyd` ("Compra USDT (GYD)", every service that
// has one) and `cupRate` ("Venta USDT (CUP)", CUP service only) -- via
// `crm_corregir_tasas_entrada_calculadora` (migration 236). The database
// recomputes invertido/retorno from the entry's own stored amount, service
// and snapshot; facturado and the global rates are never touched. Not
// audited (owner decision). Uses the caller's own SESSION Supabase client
// (never service role) so the RPC sees a real `auth.uid()`.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { mapLedgerEntry, type LedgerEntryRow } from "@/lib/calculator/ledger-read-model";

/** Same bound as the entries' rate columns (`> 0 AND < 1e9`). */
function isValidRate(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 && value < 1e9;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ entryId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
    const { entryId } = await params;

    if (!UUID_RE.test(entryId)) {
      return NextResponse.json({ error: "entryId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const usdtBuyGyd = (body as { usdtBuyGyd?: unknown } | null)?.usdtBuyGyd ?? null;
    const cupRate = (body as { cupRate?: unknown } | null)?.cupRate ?? null;
    // USDT cost of one recharge / of one 360 CUP saldo package (migration 242): same bound as the cost columns (> 0 AND < 1e6).
    const costoUsdt = (body as { costoUsdt?: unknown } | null)?.costoUsdt ?? null;

    if (
      (usdtBuyGyd === null && cupRate === null && costoUsdt === null) ||
      (usdtBuyGyd !== null && !isValidRate(usdtBuyGyd)) ||
      (cupRate !== null && !isValidRate(cupRate)) ||
      (costoUsdt !== null && !(isValidRate(costoUsdt) && costoUsdt < 1e6))
    ) {
      return NextResponse.json(
        { error: "usdtBuyGyd, cupRate and costoUsdt must be finite numbers > 0, and at least one is required" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_corregir_tasas_entrada_calculadora", {
      p_entry_id: entryId,
      p_usdt_buy_gyd: usdtBuyGyd,
      p_cup_rate: cupRate,
      // Sent only when given, so the route keeps working against a database that has not got migration 242 yet.
      ...(costoUsdt !== null ? { p_costo_usdt: costoUsdt } : {}),
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculator entries rates POST] RPC error:", error);
      throw new Error("calculator entry rates correction failed");
    }

    return NextResponse.json(
      { entry: mapLedgerEntry(data as LedgerEntryRow) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
