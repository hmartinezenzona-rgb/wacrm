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

const BETA_FEATURE = "operations_panel";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

    const { data: profile, error: profileError } = await ctx.supabase
      .from("profiles")
      .select("beta_features")
      .eq("user_id", ctx.userId)
      .maybeSingle();
    if (profileError) {
      console.error("[remittance-operations GET] profile read error:", profileError);
      throw new Error("profile read failed");
    }
    const betaFeatures = (profile?.beta_features as string[] | null) ?? [];
    if (!betaFeatures.includes(BETA_FEATURE)) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    const { data, error } = await ctx.supabase.rpc(
      "crm_operaciones_de_conversacion",
      { p_conversation_id: conversationId },
    );
    if (error) {
      if (error.code === "42501") {
        return NextResponse.json({ error: "Forbidden" }, { status: 403 });
      }
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
