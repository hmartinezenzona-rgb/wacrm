// ============================================================
// POST /api/revendedores/{contactId}/reiniciar — reset one reseller.
//
// Admin-only at both layers. The body may carry the amount the dialog
// confirmed; a stale amount raises 40001 and the route answers 409 with
// the current total (from the RPC hint) so the dialog reloads it.
// Counter-only: the RPC writes a marker and an audit row, never money.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE } from "@/lib/remittance-operations/route-helpers";
import { parseResetBody } from "@/lib/resellers/payloads";
import { mapResetResult } from "@/lib/resellers/read-model";
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

    const parsed = parseResetBody(body);
    if (!parsed.ok) {
      return NextResponse.json({ error: parsed.error }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_revendedor_reiniciar", {
      p_contact_id: contactId,
      p_motivo: parsed.value.reason,
      p_total_esperado_gyd: parsed.value.expectedTotalGyd,
    });
    if (error) {
      const errorResponse = resellerRpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[revendedores reiniciar POST] RPC error:", error);
      throw new Error("reseller reset failed");
    }

    return NextResponse.json(
      { reset: mapResetResult(data) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
