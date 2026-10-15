// ============================================================
// GET /api/remittance-operations/{operationId}/cup-plan
//
// Read-only CUP inventory block of the delivery panel (phase 3), via
// crm_inventario_cup_operacion (migration 241): before completion the
// estimated plan (which card each beneficiary's CUP leaves from), after
// it the consumptions of the operation. Card names and last 4 digits
// only. Uses the caller's own SESSION Supabase client (never service
// role) so the RPC sees a real auth.uid(). Same roles as completing the
// operation (agent+); gated behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapCupPanel } from "@/lib/cup-inventory/panel";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function GET(
  _request: Request,
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

    const { data, error } = await ctx.supabase.rpc("crm_inventario_cup_operacion", {
      p_operation_id: operationId,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations cup-plan GET] RPC error:", error);
      throw new Error("cup plan read failed");
    }

    const cupPlan = mapCupPanel(data);
    if (!cupPlan) {
      console.error("[remittance-operations cup-plan GET] unexpected payload shape");
      return NextResponse.json({ error: "Unexpected CUP plan payload" }, { status: 502 });
    }
    return NextResponse.json({ cupPlan }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
