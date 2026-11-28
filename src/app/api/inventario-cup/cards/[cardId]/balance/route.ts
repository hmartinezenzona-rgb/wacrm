// ============================================================
// POST /api/inventario-cup/cards/{cardId}/balance
//
// Sets the real balance of a CUP sending card (admin+) via `crm_ajustar_saldo_cup` (migration 256): a lower balance takes the
// difference FIFO from the card's lots, a higher one gives it back newest-first up to each lot's loaded amount. Never touches
// the daily limit. Above what was loaded the database refuses (22023 -> 400, "load a new lot").
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseBalanceBody } from "@/lib/cup-inventory/payloads";
import { mapBalanceResult } from "@/lib/cup-inventory/read-model";

export async function POST(request: Request, { params }: { params: Promise<{ cardId: string }> }) {
  try {
    const ctx = await requireRole("admin");
    const { cardId } = await params;

    if (!UUID_RE.test(cardId)) {
      return NextResponse.json({ error: "cardId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseBalanceBody(body);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

    const { data, error } = await ctx.supabase.rpc("crm_ajustar_saldo_cup", {
      p_card_id: cardId,
      p_saldo_cup: parsed.value.balanceCup,
      p_motivo: parsed.value.reason ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-cup balance POST] RPC error:", error);
      throw new Error("cup balance adjustment failed");
    }

    return NextResponse.json({ balance: mapBalanceResult(data) }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
