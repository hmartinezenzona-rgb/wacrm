// ============================================================
// POST /api/inventario-cup/lots
//
// Loads a lot of CUP (amount and the rate it cost, CUP per USDT) on an active sending card (admin+) via `crm_cargar_lote_cup`
// (migration 239). The account comes from the session.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseLotBody } from "@/lib/cup-inventory/payloads";
import { mapLotRecord } from "@/lib/cup-inventory/read-model";

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseLotBody(body);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const lot = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_cargar_lote_cup", {
      p_account_id: ctx.accountId,
      p_card_id: lot.cardId,
      p_amount_cup: lot.amountCup,
      p_rate_cup_per_usdt: lot.rateCupPerUsdt,
      p_note: lot.note ?? null,
      p_loaded_at: lot.loadedAt ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-cup lots POST] RPC error:", error);
      throw new Error("cup lot load failed");
    }

    return NextResponse.json({ lot: mapLotRecord(data) }, { status: 201, headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
