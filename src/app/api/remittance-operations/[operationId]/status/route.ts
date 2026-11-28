// ============================================================
// POST /api/remittance-operations/{operationId}/status   { estado, notify? }
//
// Moves an OPEN operation between open states (collecting_information, awaiting_deposit, deposit_verification, ready_to_transfer)
// via crm_cambiar_estado (migration 379). Completing and cancelling keep their own routes. `notify` is the bell: the customer notice of
// ready_to_transfer is sent only when it is on (default off). Uses the caller's own SESSION Supabase client (never service role) so the
// RPC sees a real auth.uid(); gated behind the operations_panel beta flag and the "agent" role. The RPC re-checks membership, that the
// operation is open and the state.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, isOperationsPanelEnabled, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

const ALLOWED_STATES: ReadonlySet<string> = new Set([
  "collecting_information",
  "awaiting_deposit",
  "deposit_verification",
  "ready_to_transfer",
]);

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

    const { estado, notify } = (body ?? {}) as { estado?: unknown; notify?: unknown };
    if (typeof estado !== "string" || !ALLOWED_STATES.has(estado)) {
      return NextResponse.json(
        { error: "estado must be one of collecting_information, awaiting_deposit, deposit_verification, ready_to_transfer" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_cambiar_estado", {
      p_operation_id: operationId,
      p_estado: estado,
      p_notify: notify === true,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations status POST] RPC error:", error);
      throw new Error("state change failed");
    }

    const result = (data ?? {}) as { changed?: boolean; new_status?: string };
    return NextResponse.json(
      { ok: true, changed: result.changed === true, newStatus: result.new_status ?? estado },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
