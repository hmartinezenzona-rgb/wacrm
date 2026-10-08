// ============================================================
// POST /api/calculator/entries/{entryId}/correct
//
// Lets an admin correct `facturado_gyd`/`invertido_gyd` on an
// already-completed calculator entry, chat-fed or manual (migration 228), via
// `crm_corregir_entrada_calculadora`, because exchange rates sometimes get
// corrected after the fact. `retorno_gyd` is always recomputed server-side
// (facturado - invertido) -- it is never sent by the client. Uses the
// caller's own SESSION Supabase client (never service role) so the RPC
// sees a real `auth.uid()`.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { mapLedgerEntry, type LedgerEntryRow } from "@/lib/calculator/ledger-read-model";

/** Validates a correction amount: must be present, a finite number, and
 * `>= 0` -- matching `crm_corregir_entrada_calculadora`'s own validation,
 * so an out-of-range value fails fast in the route before hitting the DB. */
function isValidAmount(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ entryId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
    const { entryId } = await params;

    if (!UUID_RE.test(entryId)) {
      return NextResponse.json({ error: "entryId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const facturadoGyd = (body as { facturadoGyd?: unknown } | null)?.facturadoGyd;
    const invertidoGyd = (body as { invertidoGyd?: unknown } | null)?.invertidoGyd;

    if (!isValidAmount(facturadoGyd) || !isValidAmount(invertidoGyd)) {
      return NextResponse.json(
        { error: "facturadoGyd and invertidoGyd must be finite numbers >= 0" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_corregir_entrada_calculadora", {
      p_entry_id: entryId,
      p_facturado_gyd: facturadoGyd,
      p_invertido_gyd: invertidoGyd,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculator entries correct POST] RPC error:", error);
      throw new Error("calculator entry correction failed");
    }

    return NextResponse.json(
      { entry: mapLedgerEntry(data as LedgerEntryRow) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
