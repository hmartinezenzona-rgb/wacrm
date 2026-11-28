// ============================================================
// POST /api/remittance-operations/beneficiaries/{beneficiaryId}/reassign
//
// Moves a beneficiary to a different operation via
// crm_reasignar_beneficiario. Uses the caller's own SESSION Supabase
// client (never service role) so the RPC sees a real auth.uid(), same
// as the GET route. Gated behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ beneficiaryId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { beneficiaryId } = await params;

    if (!UUID_RE.test(beneficiaryId)) {
      return NextResponse.json(
        { error: "beneficiaryId must be a UUID" },
        { status: 400 },
      );
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const targetOperationId = (body as { targetOperationId?: unknown } | null)
      ?.targetOperationId;
    if (typeof targetOperationId !== "string" || !UUID_RE.test(targetOperationId)) {
      return NextResponse.json(
        { error: "targetOperationId must be a UUID" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_reasignar_beneficiario", {
      p_beneficiary_id: beneficiaryId,
      p_target_operation_id: targetOperationId,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error(
        "[remittance-operations beneficiaries reassign POST] RPC error:",
        error,
      );
      throw new Error("beneficiary reassignment failed");
    }

    return NextResponse.json(
      { ok: true, id: data as string },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
