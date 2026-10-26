// ============================================================
// POST /api/funding-case/{caseId}/release
//
// The operator releases a committed allocation (migration 334). The
// caller's SESSION client reaches funding_caso_liberar_panel, which
// requires the agent role; funding_liberar refuses the allocation of a
// completed operation and is idempotent by key.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import type { FundingCasePanelRead } from "@/lib/funding-case/types";
import { UUID_RE, rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ caseId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { caseId } = await params;
    if (!UUID_RE.test(caseId)) {
      return NextResponse.json({ error: "caseId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }
    const allocationId = (body as { allocationId?: unknown } | null)?.allocationId;
    const idempotencyKey = (body as { idempotencyKey?: unknown } | null)?.idempotencyKey;
    const reason = (body as { reason?: unknown } | null)?.reason;

    if (typeof allocationId !== "string" || !UUID_RE.test(allocationId)) {
      return NextResponse.json({ error: "allocationId must be a UUID" }, { status: 400 });
    }
    if (
      typeof idempotencyKey !== "string" ||
      idempotencyKey.trim().length === 0 ||
      idempotencyKey.length > 200
    ) {
      return NextResponse.json({ error: "idempotencyKey is required" }, { status: 400 });
    }
    if (reason !== undefined && (typeof reason !== "string" || reason.length > 500)) {
      return NextResponse.json({ error: "reason must be a string of at most 500 characters" }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("funding_caso_liberar_panel", {
      p_allocation_id: allocationId,
      p_idempotency_key: idempotencyKey,
      p_reason: typeof reason === "string" ? reason : null,
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
