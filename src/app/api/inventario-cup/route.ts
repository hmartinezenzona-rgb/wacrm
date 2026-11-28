// ============================================================
// GET /api/inventario-cup
//
// The CUP inventory report (admin+): per sending card in priority order, its balance, FIFO lots, what was used today and the
// limit left for the current Cuba day, via `crm_inventario_cup` (migration 239). `?includeInactive=1` lists deactivated cards
// too. Uses the caller's own SESSION Supabase client (never service role) so the RPC sees a real `auth.uid()`.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { mapReport } from "@/lib/cup-inventory/read-model";

export async function GET(request: Request) {
  try {
    const ctx = await requireRole("admin");
    const includeInactive = new URL(request.url).searchParams.get("includeInactive") === "1";

    const { data, error } = await ctx.supabase.rpc("crm_inventario_cup", {
      p_account_id: ctx.accountId,
      p_include_inactive: includeInactive,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-cup GET] RPC error:", error);
      throw new Error("cup inventory report failed");
    }

    return NextResponse.json(mapReport(data), { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
