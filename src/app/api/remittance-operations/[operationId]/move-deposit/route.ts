// ============================================================
// POST /api/remittance-operations/{operationId}/move-deposit   { transId, destino? }
//
// Releases a verified deposit from the operation (no `destino`: it becomes a free ledger deposit again) or moves it to another open
// operation of the same conversation (`destino`), via crm_mover_deposito (migration 381). The deposit moves whole; the new states are muted
// (the person tells the customer). Uses the caller's own SESSION Supabase client (never service role); gated behind the operations_panel beta
// flag and the "agent" role. The RPC re-checks membership, the states and that the deposit is a verified one of this operation.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, isOperationsPanelEnabled, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { operationId } = await params;

    if (!UUID_RE.test(operationId)) {
      return NextResponse.json({ error: "operationId must be a UUID" }, { status: 400 });
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

    const { transId, destino } = (body ?? {}) as { transId?: unknown; destino?: unknown };
    if (typeof transId !== "string" || transId.trim() === "") {
      return NextResponse.json({ error: "transId is required" }, { status: 400 });
    }
    if (destino !== undefined && destino !== null && !(typeof destino === "string" && UUID_RE.test(destino))) {
      return NextResponse.json({ error: "destino must be a UUID or null" }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_mover_deposito", {
      p_operation_id: operationId,
      p_trans_id: transId.trim(),
      p_destino: destino ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations move-deposit POST] RPC error:", error);
      throw new Error("deposit move failed");
    }

    const result = (data ?? {}) as { moved?: boolean; released?: boolean; source_status?: string; target_status?: string };
    return NextResponse.json(
      {
        ok: true,
        moved: result.moved === true,
        released: result.released === true,
        sourceStatus: result.source_status ?? null,
        targetStatus: result.target_status ?? null,
      },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
