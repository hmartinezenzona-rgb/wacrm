// ============================================================
// PATCH / DELETE /api/inventario-usd/lots/{lotId}
//
// Corrects (amount / USDT paid / note) or deletes a USD lot (admin+) via `crm_corregir_lote_usd` / `crm_eliminar_lote_usd`
// (migration 355). The database refuses both once anything was taken from the lot (22023 -> 400).
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseUsdLotPatchBody } from "@/lib/usd-inventory/payloads";
import { mapUsdLotRecord } from "@/lib/usd-inventory/read-model";

const NO_STORE = { "Cache-Control": "private, no-store" };

export async function PATCH(request: Request, { params }: { params: Promise<{ lotId: string }> }) {
  try {
    const ctx = await requireRole("admin");
    const { lotId } = await params;

    if (!UUID_RE.test(lotId)) {
      return NextResponse.json({ error: "lotId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseUsdLotPatchBody(body);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const patch = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_corregir_lote_usd", {
      p_lot_id: lotId,
      p_amount_usd: patch.amountUsd ?? null,
      p_usdt_paid: patch.usdtPaid ?? null,
      p_note: patch.note ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd lots PATCH] RPC error:", error);
      throw new Error("usd lot correction failed");
    }

    return NextResponse.json({ lot: mapUsdLotRecord(data) }, { headers: NO_STORE });
  } catch (error) {
    return toErrorResponse(error);
  }
}

export async function DELETE(_request: Request, { params }: { params: Promise<{ lotId: string }> }) {
  try {
    const ctx = await requireRole("admin");
    const { lotId } = await params;

    if (!UUID_RE.test(lotId)) {
      return NextResponse.json({ error: "lotId must be a UUID" }, { status: 400 });
    }

    const { error } = await ctx.supabase.rpc("crm_eliminar_lote_usd", { p_lot_id: lotId });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd lots DELETE] RPC error:", error);
      throw new Error("usd lot delete failed");
    }

    return NextResponse.json({ deleted: lotId }, { headers: NO_STORE });
  } catch (error) {
    return toErrorResponse(error);
  }
}
