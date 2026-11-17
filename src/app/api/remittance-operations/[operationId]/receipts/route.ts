// ============================================================
// GET /api/remittance-operations/{operationId}/receipts
//
// Read-only deposit review endpoint for the in-chat remesa operations
// panel: comprobantes (declared receipts), their matched staged
// deposits, and the operation's deposit totals, via
// crm_comprobantes_de_operacion (migration 099). Uses the caller's own
// SESSION Supabase client (never service role) so the RPC sees a real
// auth.uid(), same as the sibling routes. Gated behind the
// operations_panel beta flag: a caller without the flag gets 404, not
// real data.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapOperationReceiptsPayload } from "@/lib/remittance-operations/receipts-read-model";
import type { OperationReceiptsRpcPayload } from "@/lib/remittance-operations/types";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("viewer");
    const { operationId } = await params;

    if (!UUID_RE.test(operationId)) {
      return NextResponse.json(
        { error: "operationId must be a UUID" },
        { status: 400 },
      );
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    const { data, error } = await ctx.supabase.rpc(
      "crm_comprobantes_de_operacion",
      { p_operation_id: operationId },
    );
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations receipts GET] RPC error:", error);
      throw new Error("operation receipts read failed");
    }

    const receipts = mapOperationReceiptsPayload(
      data as OperationReceiptsRpcPayload,
    );
    return NextResponse.json(
      { receipts },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}

// POST /api/remittance-operations/{operationId}/receipts   { wamid, ref?, monto? }
//
// Attaches an image of the chat as a receipt of the operation via crm_adjuntar_comprobante (migration 382). It only stores the image as a
// receipt (with the typed reference and amount, or the ones of the system's own reading of that image); it verifies nothing: the card's
// verify crosses them with the MMG ledger. Session client, operations_panel beta gate, "agent" role; the RPC re-checks membership, that the
// operation is open and that the image belongs to its conversation.
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

    const { wamid, ref, monto } = (body ?? {}) as { wamid?: unknown; ref?: unknown; monto?: unknown };
    if (typeof wamid !== "string" || wamid.trim() === "") {
      return NextResponse.json({ error: "wamid is required" }, { status: 400 });
    }
    if (ref !== undefined && ref !== null && typeof ref !== "string") {
      return NextResponse.json({ error: "ref must be a string or null" }, { status: 400 });
    }
    if (monto !== undefined && monto !== null && !(typeof monto === "number" && Number.isFinite(monto))) {
      return NextResponse.json({ error: "monto must be a number or null" }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_adjuntar_comprobante", {
      p_operation_id: operationId,
      p_wamid: wamid.trim(),
      p_ref: ref ?? null,
      p_monto: monto ?? null,
    });
    if (error) {
      // Duplicate attachment is a user-facing case, not a validation failure: answer a stable code the panel
      // translates, instead of the RPC's English sentence.
      if (error.code === "22023" && error.message?.includes("already a receipt of the operation")) {
        return NextResponse.json({ error: "receipt_already_attached" }, { status: 409 });
      }
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations receipts POST] RPC error:", error);
      throw new Error("receipt attach failed");
    }

    const result = (data ?? {}) as { comp_id?: string; reference?: string | null; amount?: number | null; prefilled?: boolean };
    return NextResponse.json(
      {
        ok: true,
        compId: result.comp_id ?? null,
        reference: result.reference ?? null,
        amount: result.amount ?? null,
        prefilled: result.prefilled === true,
      },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
