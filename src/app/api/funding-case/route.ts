// ============================================================
// GET /api/funding-case?conversationId=<uuid>
//
// Read-only funding case for the contact sidebar (migration 332). Uses
// the caller's own SESSION Supabase client so the SECURITY DEFINER RPC
// sees a real auth.uid() and checks the viewer role against the case's
// account. No beta flag: the case is the money's home since phase 3.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import type { FundingCasePanelRead } from "@/lib/funding-case/types";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

export async function GET(request: Request) {
  try {
    const ctx = await requireRole("viewer");

    const conversationId = new URL(request.url).searchParams.get("conversationId");
    if (!conversationId || !UUID_RE.test(conversationId)) {
      return NextResponse.json(
        { error: "conversationId must be a UUID" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("funding_caso_panel", {
      p_conversation: conversationId,
    });
    if (error) {
      const mapped = rpcErrorResponse(error);
      if (mapped) return mapped;
      return NextResponse.json({ error: error.message }, { status: 400 });
    }

    return NextResponse.json(data as FundingCasePanelRead);
  } catch (cause) {
    return toErrorResponse(cause);
  }
}
