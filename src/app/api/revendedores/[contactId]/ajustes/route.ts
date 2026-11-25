// ============================================================
// POST /api/revendedores/{contactId}/ajustes — manual signed adjustment.
//
// Admin-only at both layers. The amount is GYD, signed and non-zero; the
// reason is optional. crm_revendedor_ajustar (migration 397) appends a row
// and an audit entry; adjustments are append-only, a correction is a new
// adjustment.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE } from "@/lib/remittance-operations/route-helpers";
import { parseAdjustBody } from "@/lib/resellers/payloads";
import { mapAdjustmentResult } from "@/lib/resellers/read-model";
import { resellerRpcErrorResponse } from "@/lib/resellers/rpc-errors";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ contactId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
    const { contactId } = await params;

    if (!UUID_RE.test(contactId)) {
      return NextResponse.json({ error: "contactId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseAdjustBody(body);
    if (!parsed.ok) {
      return NextResponse.json({ error: parsed.error }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_revendedor_ajustar", {
      p_contact_id: contactId,
      p_monto_gyd: parsed.value.amountGyd,
      p_motivo: parsed.value.reason,
    });
    if (error) {
      const errorResponse = resellerRpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[revendedores ajustes POST] RPC error:", error);
      throw new Error("reseller adjustment failed");
    }

    return NextResponse.json(
      { adjustment: mapAdjustmentResult(data) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
