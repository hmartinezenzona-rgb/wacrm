// ============================================================
// POST /api/remittance-operations/{operationId}/beneficiaries
//
// Adds a new beneficiary to an operation via crm_agregar_beneficiario
// (migration 123) — the operations panel's fourth explicit, audited
// beneficiary action alongside the sibling correct/reassign routes. Uses
// the caller's own SESSION Supabase client (never service role) so the
// RPC sees a real auth.uid(), same as the sibling routes. Gated behind
// the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  isPlainObjectWithKeys,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

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

    const datos = (body as { datos?: unknown } | null)?.datos;
    if (!isPlainObjectWithKeys(datos)) {
      return NextResponse.json(
        { error: "datos must be a non-empty object" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_agregar_beneficiario", {
      p_operation_id: operationId,
      p_datos: datos,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations beneficiaries POST] RPC error:", error);
      throw new Error("beneficiary addition failed");
    }

    const payload = data as { id: string; complete: boolean };
    return NextResponse.json(
      { ok: true, id: payload.id, complete: payload.complete },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
