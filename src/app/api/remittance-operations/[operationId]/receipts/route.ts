// ============================================================
// GET /api/remittance-operations/{operationId}/receipts
//
// Read-only deposit review endpoint for the in-chat remesa operations
// panel: comprobantes (declared receipts), their matched staged
// deposits, and the operation's deposit totals, via
// crm_comprobantes_de_operacion (migration 099). Uses the caller's own
// SESSION Supabase client (never service role) so the RPC sees a real
// auth.uid(), same as the sibling routes. Gated behind the
// operations_panel beta flag: a caller without the flag gets 404, not
// real data.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapOperationReceiptsPayload } from "@/lib/remittance-operations/receipts-read-model";
import type { OperationReceiptsRpcPayload } from "@/lib/remittance-operations/types";
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
    const ctx = await requireRole("viewer");
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

    const { data, error } = await ctx.supabase.rpc(
      "crm_comprobantes_de_operacion",
      { p_operation_id: operationId },
    );
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations receipts GET] RPC error:", error);
      throw new Error("operation receipts read failed");
    }

    const receipts = mapOperationReceiptsPayload(
      data as OperationReceiptsRpcPayload,
    );
    return NextResponse.json(
      { receipts },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
