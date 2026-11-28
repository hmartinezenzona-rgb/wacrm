// ============================================================
// POST /api/inventario-cup/cards
//
// Creates a CUP sending card (admin+) via `crm_guardar_tarjeta_cup` (migration 239). The account always comes from the
// session, never from the body. A new card without a priority goes last; the daily limit defaults to 120,000 CUP.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseCardBody } from "@/lib/cup-inventory/payloads";
import { mapCardRecord } from "@/lib/cup-inventory/read-model";

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseCardBody(body, "create");
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const card = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_guardar_tarjeta_cup", {
      p_account_id: ctx.accountId,
      p_card_id: null,
      p_name: card.name ?? null,
      p_last4: card.last4 ?? null,
      p_priority: card.priority ?? null,
      p_daily_limit_cup: card.dailyLimitCup ?? null,
      p_active: card.active ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-cup cards POST] RPC error:", error);
      throw new Error("cup card save failed");
    }

    return NextResponse.json({ card: mapCardRecord(data) }, { status: 201, headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
