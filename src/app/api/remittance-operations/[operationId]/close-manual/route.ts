// ============================================================
// POST /api/remittance-operations/{operationId}/close-manual
//
// Closes a verified remesa (ready_to_transfer / transferring) by hand via
// crm_cerrar_operacion_manual: completed + delivery_mode closed_manually, and
// the customer is notified only when the body says `notify: true` (default false).
// Uses the caller's own SESSION Supabase client (never service role) so the
// RPC sees a real auth.uid(), same as the sibling routes. Gated behind the
// operations_panel beta flag and the "admin" role (owner included); the RPC
// re-checks owner/admin and the operation's status itself.
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

/** Services the calculator prices (migration 196); same list the RPC accepts. */
const DELIVERY_METHODS = ["cuban_card", "zelle", "clasica", "tropical", "efectivo_usd"];

/** `undefined` when absent / null, `null` (caller answers 400) when present
 *  but not one of the five services. */
function parseDeliveryMethod(body: unknown): string | null | undefined {
  const method = (body as { deliveryMethod?: unknown } | null)?.deliveryMethod;
  if (method === undefined || method === null) return undefined;
  if (typeof method !== "string" || !DELIVERY_METHODS.includes(method)) return null;
  return method;
}

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

    const notify = parseNotify(body, false);
    if (notify === null) return invalidNotifyResponse();

    const deliveryMethod = parseDeliveryMethod(body);
    if (deliveryMethod === null) {
      return NextResponse.json(
        { error: `deliveryMethod, when sent, must be one of: ${DELIVERY_METHODS.join(", ")}` },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_cerrar_operacion_manual", {
      p_operation_id: operationId,
      p_motivo: reason ?? null,
      p_notify: notify,
      ...(deliveryMethod ? { p_delivery_method: deliveryMethod } : {}),
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
