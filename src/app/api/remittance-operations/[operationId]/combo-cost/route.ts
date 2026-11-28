// ============================================================
// POST /api/remittance-operations/{operationId}/combo-cost
//
// Sets (or clears, with `costGyd: null`) what a combo cost, in GYD, via
// crm_set_combo_costo (migration 208). The calculator prices a completed combo
// from it. Uses the caller's own SESSION Supabase client (never service role)
// so the RPC sees a real auth.uid(), same as the sibling routes. Gated behind
// the operations_panel beta flag and the "admin" role (owner included); the RPC
// re-checks owner/admin and that the operation is a combo.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

/** Same ceiling the RPC enforces (exclusive). */
const MAX_COST_GYD = 1e9;

/** `undefined` when the field is missing or not a valid cost; `null` clears. */
function parseCost(body: unknown): number | null | undefined {
  const cost = (body as { costGyd?: unknown } | null)?.costGyd;
  if (cost === null) return null;
  if (typeof cost !== "number" || !Number.isFinite(cost)) return undefined;
  if (cost < 0 || cost >= MAX_COST_GYD) return undefined;
  return cost;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
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

    const costGyd = parseCost(body);
    if (costGyd === undefined) {
      return NextResponse.json(
        { error: "costGyd must be a number from 0 up to (not including) 1000000000, or null to clear it" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_set_combo_costo", {
      p_operation_id: operationId,
      p_costo_gyd: costGyd,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations combo-cost POST] RPC error:", error);
      throw new Error("combo cost update failed");
    }

    const saved = (data as { combo_costo_gyd?: number | string | null } | null)?.combo_costo_gyd;
    return NextResponse.json(
      { ok: true, costGyd: saved === null || saved === undefined ? null : Number(saved) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
