// ============================================================
// GET /api/revendedores/{contactId} — one reseller: current period,
// adjustments and reset history.
//
// Calls crm_revendedor_detalle (migration 397) with the caller's SESSION
// client; the RPC enforces account membership (viewer+). An unknown
// contact is P0002 -> 404, a stranger's contact is 42501 -> 403.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE } from "@/lib/remittance-operations/route-helpers";
import { mapResellerDetail } from "@/lib/resellers/read-model";
import { resellerRpcErrorResponse } from "@/lib/resellers/rpc-errors";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ contactId: string }> },
) {
  try {
    const ctx = await requireRole("viewer");
    const { contactId } = await params;

    if (!UUID_RE.test(contactId)) {
      return NextResponse.json({ error: "contactId must be a UUID" }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_revendedor_detalle", {
      p_contact_id: contactId,
    });
    if (error) {
      const errorResponse = resellerRpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[revendedores detail GET] RPC error:", error);
      throw new Error("reseller detail read failed");
    }

    return NextResponse.json(
      { reseller: mapResellerDetail(data) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
