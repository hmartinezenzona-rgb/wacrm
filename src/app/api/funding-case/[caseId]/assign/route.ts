// ============================================================
// POST /api/funding-case/{caseId}/assign
//
// The operator assigns GYD of the case to an open operation (migration
// 334). The caller's SESSION client reaches funding_caso_asignar_panel,
// which requires the agent role; funding_asignar enforces the balance,
// the operation's conversation and the idempotency key.
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
    const operationId = (body as { operationId?: unknown } | null)?.operationId;
    const amountGyd = (body as { amountGyd?: unknown } | null)?.amountGyd;
    const idempotencyKey = (body as { idempotencyKey?: unknown } | null)?.idempotencyKey;

    if (typeof operationId !== "string" || !UUID_RE.test(operationId)) {
      return NextResponse.json({ error: "operationId must be a UUID" }, { status: 400 });
    }
    if (typeof amountGyd !== "number" || !Number.isFinite(amountGyd) || amountGyd <= 0) {
      return NextResponse.json({ error: "amountGyd must be a positive number" }, { status: 400 });
    }
    if (
      typeof idempotencyKey !== "string" ||
      idempotencyKey.trim().length === 0 ||
      idempotencyKey.length > 200
    ) {
      return NextResponse.json({ error: "idempotencyKey is required" }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("funding_caso_asignar_panel", {
      p_case: caseId,
      p_operation_id: operationId,
      p_amount_gyd: amountGyd,
      p_idempotency_key: idempotencyKey,
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
