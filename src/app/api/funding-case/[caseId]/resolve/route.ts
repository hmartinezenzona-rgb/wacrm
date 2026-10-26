// ============================================================
// POST /api/funding-case/{caseId}/resolve
//
// Clears a funding-case incident and re-runs the reconciliation (migration
// 332). Uses the caller's SESSION Supabase client: the SECURITY DEFINER RPC
// requires the agent role in the case's account, and the engine sets the
// case back to incident if the data still shows the conflict.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import type { FundingCaseResolveRead } from "@/lib/funding-case/types";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

export async function POST(
  _request: Request,
  { params }: { params: Promise<{ caseId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { caseId } = await params;

    if (!UUID_RE.test(caseId)) {
      return NextResponse.json(
        { error: "caseId must be a UUID" },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("funding_caso_resolver_panel", {
      p_case: caseId,
    });
    if (error) {
      const mapped = rpcErrorResponse(error);
      if (mapped) return mapped;
      return NextResponse.json({ error: error.message }, { status: 400 });
    }

    return NextResponse.json(data as FundingCaseResolveRead);
  } catch (cause) {
    return toErrorResponse(cause);
  }
}
