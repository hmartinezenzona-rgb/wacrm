// ============================================================
// PATCH /api/inventario-cup/cards/{cardId}
//
// Updates, reorders (priority) or deactivates a CUP sending card (admin+) via `crm_guardar_tarjeta_cup` (migration 239). Only
// the named fields change; `last4: null` clears the stored digits.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseCardBody } from "@/lib/cup-inventory/payloads";
import { mapCardRecord } from "@/lib/cup-inventory/read-model";

export async function PATCH(request: Request, { params }: { params: Promise<{ cardId: string }> }) {
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

    const parsed = parseCardBody(body, "update");
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const card = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_guardar_tarjeta_cup", {
      p_account_id: ctx.accountId,
      p_card_id: cardId,
      p_name: card.name ?? null,
      p_last4: card.last4 ?? null,
      p_priority: card.priority ?? null,
      p_daily_limit_cup: card.dailyLimitCup ?? null,
      p_active: card.active ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-cup cards PATCH] RPC error:", error);
      throw new Error("cup card save failed");
    }

    return NextResponse.json({ card: mapCardRecord(data) }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
