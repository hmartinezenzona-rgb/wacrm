// ============================================================
// POST /api/remittance-operations/beneficiaries/{beneficiaryId}/remove
//
// Removes a current recipient of an open operation via crm_quitar_beneficiario (migration 377): the row is kept as
// 'reemplazado' and the removal is audited. Uses the caller's own SESSION Supabase client (never service role) so the RPC
// sees a real auth.uid(), same as the sibling routes. Gated behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function POST(
  _request: Request,
  { params }: { params: Promise<{ beneficiaryId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { beneficiaryId } = await params;

    if (!UUID_RE.test(beneficiaryId)) {
      return NextResponse.json({ error: "beneficiaryId must be a UUID" }, { status: 400 });
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_quitar_beneficiario", {
      p_beneficiary_id: beneficiaryId,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations beneficiaries remove POST] RPC error:", error);
      throw new Error("beneficiary removal failed");
    }

    const result = (data ?? {}) as { id?: string; complete?: boolean };
    return NextResponse.json(
      { ok: true, id: result.id ?? beneficiaryId, complete: result.complete === true },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
