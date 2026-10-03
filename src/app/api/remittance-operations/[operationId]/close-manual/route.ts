// ============================================================
// POST /api/remittance-operations/{operationId}/close-manual
//
// Closes a verified remesa (ready_to_transfer / transferring) by hand via
// crm_cerrar_operacion_manual: completed + delivery_mode closed_manually, and
// the customer is NOT notified (the notifier skips closed_manually).
// Uses the caller's own SESSION Supabase client (never service role) so the
// RPC sees a real auth.uid(), same as the sibling routes. Gated behind the
// operations_panel beta flag and the "admin" role (owner included); the RPC
// re-checks owner/admin and the operation's status itself.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

const MAX_REASON_LENGTH = 500;

function parseReason(body: unknown): string | null {
  const reason = (body as { reason?: unknown } | null)?.reason;
  if (typeof reason !== "string") return null;
  const trimmed = reason.trim();
  if (trimmed.length < 1 || trimmed.length > MAX_REASON_LENGTH) return null;
  return trimmed;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
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

    const reason = parseReason(body);
    if (!reason) {
      return NextResponse.json(
        { error: "reason must be a string of 1 to 500 characters" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_cerrar_operacion_manual", {
      p_operation_id: operationId,
      p_motivo: reason,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error(
        "[remittance-operations close-manual POST] RPC error:",
        error,
      );
      throw new Error("manual close failed");
    }

    const result = data as { new_status: string; completed_at?: string | null };
    return NextResponse.json(
      { ok: true, newStatus: result.new_status, completedAt: result.completed_at ?? null },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
