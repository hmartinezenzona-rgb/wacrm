// ============================================================
// POST /api/inventario-usd/cards/{cardId}/balance
//
// Sets the real balance of a Clásica / Tropical card (admin+) via `crm_ajustar_saldo_usd` (migration 355): a lower balance takes
// the difference FIFO from the card's lots, a higher one gives it back newest-first up to each lot's loaded amount. Never
// touches the monthly limit. Above what was loaded the database refuses (22023 -> 400, "load a new lot").
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseUsdBalanceBody } from "@/lib/usd-inventory/payloads";
import { mapUsdBalanceResult } from "@/lib/usd-inventory/read-model";

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

    const parsed = parseUsdBalanceBody(body);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

    const { data, error } = await ctx.supabase.rpc("crm_ajustar_saldo_usd", {
      p_card_id: cardId,
      p_saldo_usd: parsed.value.balanceUsd,
      p_motivo: parsed.value.reason ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd balance POST] RPC error:", error);
      throw new Error("usd balance adjustment failed");
    }

    return NextResponse.json({ balance: mapUsdBalanceResult(data) }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
