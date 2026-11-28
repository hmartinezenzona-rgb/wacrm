// ============================================================
// POST /api/remittance-operations/{operationId}/delete
//
// Soft-deletes a remesa via crm_eliminar_operacion (status cancelled, audited
// with the reason). The RPC refuses completed, cancelled and verified remesas
// and any remesa holding a consumed MMG deposit.
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

/** The reason is optional now: `undefined` when absent or blank, `null`
 *  (caller answers 400) when present but not a string or over the limit. */
function parseReason(body: unknown): string | null | undefined {
  const reason = (body as { reason?: unknown } | null)?.reason;
  if (reason === undefined) return undefined;
  if (typeof reason !== "string") return null;
  const trimmed = reason.trim();
  if (trimmed.length > MAX_REASON_LENGTH) return null;
  return trimmed === "" ? undefined : trimmed;
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
    if (reason === null) {
      return NextResponse.json(
        { error: "reason, when sent, must be a string of at most 500 characters" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_eliminar_operacion", {
      p_operation_id: operationId,
      p_motivo: reason ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error(
        "[remittance-operations delete POST] RPC error:",
        error,
      );
      throw new Error("operation delete failed");
    }

    const result = data as { new_status: string; completed_at?: string | null };
    return NextResponse.json(
      { ok: true, newStatus: result.new_status },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
