// ============================================================
// POST /api/revendedores/reiniciar — reset all resellers' counters.
//
// Admin-only at both layers: requireRole("admin") here and
// is_account_member(account, 'admin') inside crm_revendedores_reiniciar_todos
// (migration 397). The body may carry the grand total the dialog confirmed;
// a stale amount raises 40001 and the route answers 409 with the current
// grand total (from the RPC hint) so the dialog reloads it.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { parseResetAllBody } from "@/lib/resellers/payloads";
import { mapBatchResult } from "@/lib/resellers/read-model";
import { resellerRpcErrorResponse } from "@/lib/resellers/rpc-errors";

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseResetAllBody(body);
    if (!parsed.ok) {
      return NextResponse.json({ error: parsed.error }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc(
      "crm_revendedores_reiniciar_todos",
      {
        p_account_id: ctx.accountId,
        p_motivo: parsed.value.reason,
        p_total_esperado_gyd: parsed.value.expectedGrandTotalGyd,
      },
    );
    if (error) {
      const errorResponse = resellerRpcErrorResponse(error, "currentGrandTotalGyd");
      if (errorResponse) return errorResponse;
      console.error("[revendedores reiniciar POST] RPC error:", error);
      throw new Error("reseller reset all failed");
    }

    return NextResponse.json(
      { batch: mapBatchResult(data) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
