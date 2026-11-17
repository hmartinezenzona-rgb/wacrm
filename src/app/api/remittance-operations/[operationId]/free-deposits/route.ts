// ============================================================
// GET /api/remittance-operations/{operationId}/free-deposits
//
// The MMG ledger deposits nobody owns (crm_depositos_sin_dueno, migration 380), newest first, for the panel's "link a deposit" picker.
// The picker links one with the existing verify route, so this is a read. Uses the caller's own SESSION Supabase client (never service
// role); gated behind the operations_panel beta flag and the "agent" role (the RPC re-checks membership).
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, isOperationsPanelEnabled, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import type { FreeDeposit, FreeDepositRpcRow } from "@/lib/remittance-operations/types";

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

    const { data, error } = await ctx.supabase.rpc("crm_depositos_sin_dueno", { p_operation_id: operationId });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations free-deposits GET] RPC error:", error);
      throw new Error("free deposits read failed");
    }

    const deposits: FreeDeposit[] = ((data ?? []) as FreeDepositRpcRow[]).map((row) => ({
      transId: row.trans_id,
      amount: Number(row.amount),
      currency: row.currency,
      receivedAt: row.received_at,
      holder: row.holder ?? null,
    }));
    return NextResponse.json({ deposits }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
