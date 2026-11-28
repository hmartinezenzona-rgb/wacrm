// ============================================================
// PATCH /api/inventario-usd/cards/{cardId}
//
// Updates, reorders (priority) or deactivates a Clásica / Tropical card (admin+) via `crm_guardar_tarjeta_usd` (migration 355).
// Only the named fields change; `last4: null` clears the stored digits. The service of a card never changes.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseUsdCardBody } from "@/lib/usd-inventory/payloads";
import { mapUsdCardRecord } from "@/lib/usd-inventory/read-model";

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

    const parsed = parseUsdCardBody(body, "update");
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
    const card = parsed.value;

    const { data, error } = await ctx.supabase.rpc("crm_guardar_tarjeta_usd", {
      p_account_id: ctx.accountId,
      p_card_id: cardId,
      p_service: null,
      p_name: card.name ?? null,
      p_last4: card.last4 ?? null,
      p_priority: card.priority ?? null,
      p_monthly_limit_usd: card.monthlyLimitUsd ?? null,
      p_active: card.active ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[inventario-usd cards PATCH] RPC error:", error);
      throw new Error("usd card save failed");
    }

    return NextResponse.json({ card: mapUsdCardRecord(data) }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
