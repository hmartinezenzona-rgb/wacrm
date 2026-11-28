// ============================================================
// GET  /api/remittance-operations?conversationId=<uuid>
// POST /api/remittance-operations  { conversationId, servicio, monto }  (creates an operation from scratch, crm_crear_operacion,
//                                   migration 378; same session client and beta gate as the sibling writes)
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
import { isOperationService } from "@/lib/remittance-operations/services";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { mapPlannedSplitRows, mapQuoteRows, mapRemittanceOperationsRows } from "@/lib/remittance-operations/read-model";
import { mapOperationReceiptsPayload } from "@/lib/remittance-operations/receipts-read-model";
import type {
  ConversationQuoteRead,
  ConversationQuoteRpcRow,
  PlannedSplitRead,
  PlannedSplitRpcRow,
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

/**
 * Fetches the bot's current quote (`crm_cotizacion_de_conversacion`, migration
 * 187). Never throws: it is context for the panel, so a failed call (or the
 * function not existing yet, e.g. production before 187) is logged and mapped
 * to `null` instead of costing the operations response. The operations read
 * already enforced membership, so a 42501 here is not a separate gate.
 */
async function fetchConversationQuote(
  supabase: SessionSupabaseClient,
  conversationId: string,
): Promise<ConversationQuoteRead | null> {
  try {
    const { data, error } = await supabase.rpc("crm_cotizacion_de_conversacion", {
      p_conversation_id: conversationId,
    });
    if (error) {
      console.error("[remittance-operations GET] quote RPC error:", error);
      return null;
    }
    return mapQuoteRows(data as ConversationQuoteRpcRow[] | null);
  } catch (cause) {
    console.error("[remittance-operations GET] quote read threw:", cause);
    return null;
  }
}

/**
 * Fetches the split the bot planned before any deposit (`crm_reparto_planeado_de_conversacion`, migration 370). Never
 * throws, like the quote: a failed call (or the function not existing yet) is logged and mapped to `null`.
 */
async function fetchPlannedSplit(
  supabase: SessionSupabaseClient,
  conversationId: string,
): Promise<PlannedSplitRead | null> {
  try {
    const { data, error } = await supabase.rpc("crm_reparto_planeado_de_conversacion", {
      p_conversation_id: conversationId,
    });
    if (error) {
      console.error("[remittance-operations GET] planned split RPC error:", error);
      return null;
    }
    return mapPlannedSplitRows(data as PlannedSplitRpcRow[] | null);
  } catch (cause) {
    console.error("[remittance-operations GET] planned split read threw:", cause);
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
    const quotePromise = fetchConversationQuote(ctx.supabase, conversationId);
    const plannedSplitPromise = fetchPlannedSplit(ctx.supabase, conversationId);
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

    const quote = await quotePromise;
    const plannedSplit = await plannedSplitPromise;

    return NextResponse.json(
      { ...result, receiptsByOperationId, quote, plannedSplit },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("agent");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const { conversationId, servicio, monto } = (body ?? {}) as {
      conversationId?: unknown;
      servicio?: unknown;
      monto?: unknown;
    };
    if (typeof conversationId !== "string" || !UUID_RE.test(conversationId)) {
      return NextResponse.json({ error: "conversationId must be a UUID" }, { status: 400 });
    }
    if (!isOperationService(servicio)) {
      return NextResponse.json({ error: "servicio is not a known service" }, { status: 400 });
    }
    if (monto !== undefined && monto !== null && !(typeof monto === "number" && Number.isFinite(monto))) {
      return NextResponse.json({ error: "monto must be a number" }, { status: 400 });
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_crear_operacion", {
      p_conversation_id: conversationId,
      p_servicio: servicio,
      p_monto: monto ?? null,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations POST] RPC error:", error);
      throw new Error("operation creation failed");
    }

    const result = (data ?? {}) as { id?: string; service?: string };
    return NextResponse.json(
      { ok: true, id: result.id, service: result.service ?? servicio },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
