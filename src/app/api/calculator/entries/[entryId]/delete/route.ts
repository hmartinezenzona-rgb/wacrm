// ============================================================
// POST /api/calculator/entries/{entryId}/delete
//
// Lets an admin delete a calculator entry, chat-fed (completed or pending) or manual (migration 228), via
// `crm_eliminar_entrada_calculadora` (migration 226). The entry becomes a durable void (the feed never revives it), stops counting in the Calculator,
// Finanzas and the dashboard, and the operation is untouched. Uses the caller's own SESSION Supabase client (never
// service role) so the RPC sees a real `auth.uid()`.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

export async function POST(
  _request: Request,
  { params }: { params: Promise<{ entryId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
    const { entryId } = await params;

    if (!UUID_RE.test(entryId)) {
      return NextResponse.json({ error: "entryId must be a UUID" }, { status: 400 });
    }

    const { error } = await ctx.supabase.rpc("crm_eliminar_entrada_calculadora", { p_entry_id: entryId });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculator entries delete POST] RPC error:", error);
      throw new Error("calculator entry deletion failed");
    }

    return NextResponse.json({ deleted: true, entryId }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
