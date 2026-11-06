// ============================================================
// GET /api/inventario-usd
//
// The USD card inventory report (admin+): per Clásica / Tropical card, its balance, FIFO lots, what was used this Cuba month and
// the monthly limit left, plus per-service totals, via `crm_inventario_usd` (migration 355). `?includeInactive=1` lists
// deactivated cards too. Uses the caller's own SESSION Supabase client (never service role) so the RPC sees a real `auth.uid()`.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { mapUsdReport } from "@/lib/usd-inventory/read-model";

export async function GET(request: Request) {
  try {
    const ctx = await requireRole("admin");
    const includeInactive = new URL(request.url).searchParams.get("includeInactive") === "1";

    const { data, error } = await ctx.supabase.rpc("crm_inventario_usd", {
      p_account_id: ctx.accountId,
      p_include_inactive: includeInactive,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd GET] RPC error:", error);
      throw new Error("usd inventory report failed");
    }

    return NextResponse.json(mapUsdReport(data), { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
