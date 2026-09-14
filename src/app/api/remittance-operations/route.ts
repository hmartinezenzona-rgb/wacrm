// ============================================================
// GET /api/remittance-operations?conversationId=<uuid>
//
// Read-only Slice 5 endpoint for the in-chat remesa operations panel.
// Uses the caller's own SESSION Supabase client (never service role) so
// `crm_operaciones_de_conversacion` (migration 097) sees a real
// `auth.uid()` — service-role calls have no `auth.uid()` and would read
// as automation to every later guard/lock (design decisions 3, 12).
//
// Gated behind `profiles.beta_features` containing 'operations_panel'
// (design decision 8) for BOTH the UI (Slice 5 mount) and here: a caller
// who bypasses the hidden UI and calls this route directly must still get
// a 404, not real data.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapRemittanceOperationsRows } from "@/lib/remittance-operations/read-model";
import type { RemittanceOperationsRpcRow } from "@/lib/remittance-operations/types";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function GET(request: Request) {
  try {
    const ctx = await requireRole("viewer");

    const { searchParams } = new URL(request.url);
    const conversationId = searchParams.get("conversationId");
    if (!conversationId || !UUID_RE.test(conversationId)) {
      return NextResponse.json(
        { error: "conversationId must be a UUID" },
        { status: 400 },
      );
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    const { data, error } = await ctx.supabase.rpc(
      "crm_operaciones_de_conversacion",
      { p_conversation_id: conversationId },
    );
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations GET] RPC error:", error);
      throw new Error("remittance operations read failed");
    }

    const result = mapRemittanceOperationsRows(
      (data ?? []) as RemittanceOperationsRpcRow[],
    );
    return NextResponse.json(result, {
      headers: { "Cache-Control": "private, no-store" },
    });
  } catch (error) {
    return toErrorResponse(error);
  }
}
