// ============================================================
// POST /api/remittance-operations/{operationId}/service
//
// Changes an open operation's service (Tarjeta CUP, Zelle, Clásica, Tropical, Efectivo USD, Recarga, Combo or Visa)
// via crm_cambiar_servicio (migration 222). The RPC recalculates the quote, retires the recipients that do not fit
// the new service and messages nobody. Uses the caller's own SESSION Supabase client (never service role) so the RPC
// sees a real auth.uid() for its authorization and audit trail, same as the sibling routes. Gated behind the
// operations_panel beta flag and the "agent" role; the RPC re-checks membership and that the operation is open.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";
import { isOperationService } from "@/lib/remittance-operations/services";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { operationId } = await params;

    if (!UUID_RE.test(operationId)) {
      return NextResponse.json({ error: "operationId must be a UUID" }, { status: 400 });
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const servicio = (body as { servicio?: unknown } | null)?.servicio;
    if (!isOperationService(servicio)) {
      return NextResponse.json(
        { error: "servicio must be one of cuban_card, zelle, clasica, tropical, efectivo_usd, recarga, combo, visa" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_cambiar_servicio", {
      p_operation_id: operationId,
      p_servicio: servicio,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations service POST] RPC error:", error);
      throw new Error("service change failed");
    }

    const summary = data as { service?: string; changed?: boolean } | null;
    return NextResponse.json(
      { ok: true, service: summary?.service ?? servicio, changed: summary?.changed ?? true },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
