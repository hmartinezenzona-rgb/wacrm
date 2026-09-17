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
import { mapOperationReceiptsPayload } from "@/lib/remittance-operations/receipts-read-model";
import type {
  OperationReceiptsRead,
  OperationReceiptsRpcPayload,
  RemittanceOperationsRpcRow,
} from "@/lib/remittance-operations/types";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

/** Same caller-session client type `isOperationsPanelEnabled` already
 *  takes — there's no exported alias for it, so this borrows its
 *  parameter type rather than importing `@supabase/supabase-js` and
 *  risking a mismatch with the narrowed session client type. */
type SessionSupabaseClient = Parameters<typeof isOperationsPanelEnabled>[0];

/**
 * Fetches one operation's `crm_comprobantes_de_operacion` receipts read —
 * same RPC, same argument name, same mapping helper as the sibling
 * `[operationId]/receipts` route, reused rather than reimplemented. Never
 * throws: a failed call is logged and mapped to `null` so one bad receipts
 * read can't fail the whole `/remittance-operations` request — the client
 * falls back to fetching that operation's receipts itself (the sibling
 * route stays for exactly that).
 */
async function fetchOperationReceiptsRead(
  supabase: SessionSupabaseClient,
  operationId: string,
): Promise<OperationReceiptsRead | null> {
  try {
    const { data, error } = await supabase.rpc("crm_comprobantes_de_operacion", {
      p_operation_id: operationId,
    });
    if (error) {
      console.error(
        "[remittance-operations GET] receipts prefetch RPC error:",
        operationId,
        error,
      );
      return null;
    }
    return mapOperationReceiptsPayload(data as OperationReceiptsRpcPayload);
  } catch (cause) {
    // Supabase reports a query failure through `error`, but a transport
    // failure rejects instead, and these calls run inside a Promise.all —
    // one rejection would take the whole operations response down with it.
    // The prefetch is a convenience; losing it must never cost the panel.
    console.error(
      "[remittance-operations GET] receipts prefetch threw:",
      operationId,
      cause,
    );
    return null;
  }
}

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

    // Prefetch every operation's receipts alongside the operations list —
    // one round trip instead of the operations panel waiting for
    // `crm_operaciones_de_conversacion`, THEN mounting a card, THEN
    // firing a second fetch for its receipts (panel-26). `.map(async …)`
    // invokes `ctx.supabase.rpc(...)` for every operation synchronously
    // before any of those calls is awaited — genuinely parallel, not a
    // sequential loop — and `Promise.all` waits for all of them together.
    const receiptsEntries = await Promise.all(
      result.operations.map(async (operation) => {
        const receipts = await fetchOperationReceiptsRead(
          ctx.supabase,
          operation.id,
        );
        return [operation.id, receipts] as const;
      }),
    );
    const receiptsByOperationId: Record<string, OperationReceiptsRead> = {};
    for (const [operationId, receipts] of receiptsEntries) {
      if (receipts) receiptsByOperationId[operationId] = receipts;
    }

    return NextResponse.json(
      { ...result, receiptsByOperationId },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
