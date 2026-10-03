// ============================================================
// POST /api/remittance-operations/{operationId}/verify
//
// Applies an agent-initiated panel deposit verification via
// crm_verificar_deposito, matching declared receipts against staged
// deposits by (ref, amount) line items. Uses the caller's own SESSION
// Supabase client (never service role) so the RPC sees a real
// auth.uid(), same as the sibling routes. Gated behind the
// operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapVerifyDepositPayload } from "@/lib/remittance-operations/receipts-read-model";
import type {
  VerifyDepositItem,
  VerifyDepositRpcPayload,
} from "@/lib/remittance-operations/types";
import {
  UUID_RE,
  invalidNotifyResponse,
  isOperationsPanelEnabled,
  parseNotify,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

const MAX_ITEMS = 5;

function isValidItem(value: unknown): value is VerifyDepositItem {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as { ref?: unknown; amount?: unknown };
  return (
    typeof candidate.ref === "string" &&
    candidate.ref.length > 0 &&
    typeof candidate.amount === "number" &&
    Number.isFinite(candidate.amount) &&
    candidate.amount > 0
  );
}

function parseItems(body: unknown): VerifyDepositItem[] | null {
  const items = (body as { items?: unknown } | null)?.items;
  if (!Array.isArray(items)) return null;
  if (items.length < 1 || items.length > MAX_ITEMS) return null;
  if (!items.every(isValidItem)) return null;
  return items.map((item) => ({ ref: item.ref, amount: item.amount }));
}

export async function POST(
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

    const items = parseItems(body);
    if (!items) {
      return NextResponse.json(
        {
          error:
            "items must be an array of 1-5 objects with a non-empty ref and a positive finite amount",
        },
        { status: 400 },
      );
    }

    const notify = parseNotify(body, true);
    if (notify === null) return invalidNotifyResponse();

    const { data, error } = await ctx.supabase.rpc("crm_verificar_deposito", {
      p_operation_id: operationId,
      p_items: items,
      p_notify: notify,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations verify POST] RPC error:", error);
      throw new Error("deposit verification failed");
    }

    const result = mapVerifyDepositPayload(data as VerifyDepositRpcPayload);
    return NextResponse.json(
      { ok: true, result },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
