// ============================================================
// POST /api/inventario-usd/cards
//
// Creates a Clásica / Tropical card (admin+) via `crm_guardar_tarjeta_usd` (migration 355). The account always comes from the
// session, never from the body. A new card without a priority goes last of its service; the monthly limit defaults to 5,000 USD.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseUsdCardBody } from "@/lib/usd-inventory/payloads";
import { mapUsdCardRecord } from "@/lib/usd-inventory/read-model";

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const parsed = parseUsdCardBody(body, "create");
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const card = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_guardar_tarjeta_usd", {
      p_account_id: ctx.accountId,
      p_card_id: null,
      p_service: card.service ?? null,
      p_name: card.name ?? null,
      p_last4: card.last4 ?? null,
      p_priority: card.priority ?? null,
      p_monthly_limit_usd: card.monthlyLimitUsd ?? null,
      p_active: card.active ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd cards POST] RPC error:", error);
      throw new Error("usd card save failed");
    }

    return NextResponse.json({ card: mapUsdCardRecord(data) }, { status: 201, headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
