// ============================================================
// POST /api/inventario-usd/lots
//
// Loads a lot of USD (amount received and the USDT it cost) on an active Clásica / Tropical card (admin+) via
// `crm_cargar_lote_usd` (migration 355). The lot rate (USD per USDT) is derived by the database. The account comes from the
// session.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseUsdLotBody } from "@/lib/usd-inventory/payloads";
import { mapUsdLotRecord } from "@/lib/usd-inventory/read-model";

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseUsdLotBody(body);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const lot = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_cargar_lote_usd", {
      p_account_id: ctx.accountId,
      p_card_id: lot.cardId,
      p_amount_usd: lot.amountUsd,
      p_usdt_paid: lot.usdtPaid,
      p_loaded_at: lot.loadedAt ?? null,
      p_note: lot.note ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd lots POST] RPC error:", error);
      throw new Error("usd lot load failed");
    }

    return NextResponse.json({ lot: mapUsdLotRecord(data) }, { status: 201, headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
