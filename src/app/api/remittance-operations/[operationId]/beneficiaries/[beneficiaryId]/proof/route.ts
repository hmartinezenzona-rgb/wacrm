// ============================================================
// POST /api/remittance-operations/{operationId}/beneficiaries/{beneficiaryId}/proof
//
// Records one beneficiary's delivery proof via
// crm_registrar_prueba_beneficiario (migration 143) — the per-beneficiary
// counterpart to the deliver route: a remesa with 2+ current
// beneficiaries sends one proof image per beneficiary before the single
// crm_entregar_operacion call. Uses the caller's own SESSION Supabase
// client (never service role) so the RPC sees a real auth.uid(), same as
// the sibling routes. Gated behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export interface BeneficiaryProofEvidence {
  wamid: string;
  path?: string;
  caption?: string;
}

/** `undefined` is fine (the field is optional); present means non-empty
 *  and within the RPC's own CHECK bounds (migration 143). */
function isValidOptionalString(value: unknown, maxLength: number): boolean {
  if (value === undefined) return true;
  return typeof value === "string" && value.length > 0 && value.length <= maxLength;
}

function parseEvidence(body: unknown): BeneficiaryProofEvidence | null {
  const evidence = (body as { evidence?: unknown } | null)?.evidence;
  if (typeof evidence !== "object" || evidence === null || Array.isArray(evidence)) {
    return null;
  }

  const candidate = evidence as { wamid?: unknown; path?: unknown; caption?: unknown };
  if (typeof candidate.wamid !== "string" || candidate.wamid.length === 0 || candidate.wamid.length > 500) {
    return null;
  }
  if (!isValidOptionalString(candidate.path, 500)) return null;
  if (!isValidOptionalString(candidate.caption, 1024)) return null;

  const result: BeneficiaryProofEvidence = { wamid: candidate.wamid };
  if (candidate.path !== undefined) result.path = candidate.path as string;
  if (candidate.caption !== undefined) result.caption = candidate.caption as string;
  return result;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string; beneficiaryId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { operationId, beneficiaryId } = await params;

    if (!UUID_RE.test(operationId)) {
      return NextResponse.json(
        { error: "operationId must be a UUID" },
        { status: 400 },
      );
    }
    if (!UUID_RE.test(beneficiaryId)) {
      return NextResponse.json(
        { error: "beneficiaryId must be a UUID" },
        { status: 400 },
      );
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

    const evidence = parseEvidence(body);
    if (!evidence) {
      return NextResponse.json(
        {
          error:
            "evidence must be an object with a non-empty wamid (max 500 chars) and an optional non-empty path (max 500 chars) / caption (max 1024 chars)",
        },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_registrar_prueba_beneficiario", {
      p_operation_id: operationId,
      p_beneficiary_id: beneficiaryId,
      p_evidence: evidence,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations beneficiary proof POST] RPC error:", error);
      throw new Error("beneficiary proof registration failed");
    }

    const payload = data as { registered: boolean; missing: number };
    return NextResponse.json(
      { ok: true, registered: payload.registered, missing: payload.missing },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
