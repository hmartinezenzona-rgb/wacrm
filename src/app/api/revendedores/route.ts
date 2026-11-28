// ============================================================
// GET /api/revendedores — Finanzas "Revendedores" list + grand total.
//
// Calls crm_revendedores_resumen (migration 397) with the caller's SESSION
// client so the RPC sees a real auth.uid() and enforces account membership
// (viewer+, i.e. any member) itself. The panel only avoids useless calls;
// the database is the authorization boundary.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapResellerSummaryRead } from "@/lib/resellers/read-model";
import { resellerRpcErrorResponse } from "@/lib/resellers/rpc-errors";

export async function GET() {
  try {
    const ctx = await requireRole("viewer");

    const { data, error } = await ctx.supabase.rpc("crm_revendedores_resumen", {
      p_account_id: ctx.accountId,
    });
    if (error) {
      const errorResponse = resellerRpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[revendedores GET] RPC error:", error);
      throw new Error("reseller summary read failed");
    }

    return NextResponse.json(mapResellerSummaryRead(data), {
      headers: { "Cache-Control": "private, no-store" },
    });
  } catch (error) {
    return toErrorResponse(error);
  }
}
