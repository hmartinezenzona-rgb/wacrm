// ============================================================
// POST /api/remittance-operations/{operationId}/reparto
//
// Replaces ALL the card shares of a remesa operation in one atomic, audited step via crm_editar_reparto (migration
// 394). Body: { partes: [{ id, beneficiary_type, name, card_number, phone, amount, currency }] } where `id` is the
// current share's uuid or null for a new share. The RPC owns every rule (share fields, the sum equal to the operation
// total, the closed-operation role check); this route only checks the envelope and turns the RPC errors into HTTP
// statuses with Spanish messages. Uses the caller's own SESSION Supabase client (never service role) so the RPC sees a
// real auth.uid(), same as the sibling routes. Gated behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";
import { translateSplitEditError } from "@/lib/remittance-operations/split-edit-errors";

const PARTES_ERROR = "Se necesitan al menos 2 partes, cada una con sus datos";
const FORBIDDEN_ERROR = "No tienes permiso para editar el reparto de esta operación";

function isShareList(value: unknown): value is Array<Record<string, unknown>> {
  return (
    Array.isArray(value) &&
    value.length >= 2 &&
    value.every((share) => typeof share === "object" && share !== null && !Array.isArray(share))
  );
}

interface EditSplitRpcResult {
  retired?: string[];
  created?: string[];
  kept?: string[];
  complete?: boolean;
}

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

    const partes = (body as { partes?: unknown } | null)?.partes;
    if (!isShareList(partes)) {
      return NextResponse.json({ error: PARTES_ERROR }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_editar_reparto", {
      p_operation_id: operationId,
      p_partes: partes,
    });
    if (error) {
      if (error.code === "42501") {
        return NextResponse.json({ error: FORBIDDEN_ERROR }, { status: 403 });
      }
      if (error.code === "22023") {
        return NextResponse.json(
          { error: translateSplitEditError(error.message ?? "") },
          { status: 400 },
        );
      }
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations reparto POST] RPC error:", error);
      throw new Error("split edit failed");
    }

    const summary = data as EditSplitRpcResult | null;
    return NextResponse.json(
      {
        ok: true,
        retired: summary?.retired ?? [],
        created: summary?.created ?? [],
        kept: summary?.kept ?? [],
        complete: summary?.complete ?? false,
      },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
