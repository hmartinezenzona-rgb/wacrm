// ============================================================
// POST /api/remittance-operations/{operationId}/force-verify
//
// Applies an admin-initiated forced deposit verification via
// crm_forzar_verificacion — the escalation path for when no staged
// deposit can be matched automatically or manually. Uses the caller's
// own SESSION Supabase client (never service role) so the RPC sees a
// real auth.uid(), same as the sibling routes. Gated behind the
// operations_panel beta flag, and requires the "admin" role (stronger
// than the "agent" verify route: this bypasses matching entirely).
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  invalidNotifyResponse,
  isOperationsPanelEnabled,
  parseNotify,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

const MAX_REASON_LENGTH = 500;

/** The reason is optional: `undefined` when absent or blank, `null`
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

    const notify = parseNotify(body, true);
    if (notify === null) return invalidNotifyResponse();

    const { data, error } = await ctx.supabase.rpc("crm_forzar_verificacion", {
      p_operation_id: operationId,
      p_reason: reason ?? null,
      p_notify: notify,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error(
        "[remittance-operations force-verify POST] RPC error:",
        error,
      );
      throw new Error("forced deposit verification failed");
    }

    return NextResponse.json(
      { ok: true, newStatus: (data as { new_status: string }).new_status },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
