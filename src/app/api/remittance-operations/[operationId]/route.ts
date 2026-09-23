// ============================================================
// PATCH /api/remittance-operations/{operationId}
//
// Applies an agent-initiated correction to a remittance operation via
// crm_corregir_operacion. Uses the caller's own SESSION Supabase client
// (never service role) so the RPC sees a real auth.uid() for its own
// authorization and audit trail, same as the GET route. Gated behind
// the operations_panel beta flag: a caller without the flag gets 404,
// not a real write path.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  isPlainObjectWithKeys,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function PATCH(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { operationId } = await params;

    if (!UUID_RE.test(operationId)) {
      return NextResponse.json(
        { error: "operationId must be a UUID" },
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

    const cambios = (body as { cambios?: unknown } | null)?.cambios;
    if (!isPlainObjectWithKeys(cambios)) {
      return NextResponse.json(
        { error: "cambios must be a non-empty object" },
        { status: 400 },
      );
    }

    const { error } = await ctx.supabase.rpc("crm_corregir_operacion", {
      p_operation_id: operationId,
      p_cambios: cambios,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations PATCH] RPC error:", error);
      throw new Error("operation correction failed");
    }

    return NextResponse.json(
      { ok: true },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
