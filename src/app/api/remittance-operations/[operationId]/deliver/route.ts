// ============================================================
// POST /api/remittance-operations/{operationId}/deliver
//
// Completes a ready_to_transfer remittance from the operations panel,
// via crm_entregar_operacion (migration 101) — which reuses the exact
// legacy stage transition the old Kanban board performs by hand (move
// the deal to Entregada), recording what evidence backed the handoff.
// Uses the caller's own SESSION Supabase client (never service role) so
// the RPC sees a real auth.uid(), same as the sibling routes. Gated
// behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import type {
  DeliveryEvidenceMode,
  DeliveryEvidenceRpc,
} from "@/lib/remittance-operations/delivery";
import {
  UUID_RE,
  invalidNotifyResponse,
  isOperationsPanelEnabled,
  parseNotify,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

const VALID_MODES: ReadonlyArray<DeliveryEvidenceMode> = [
  "proof_sent",
  "no_proof",
  "skip_proof",
];

/** `undefined` is fine (the field is optional); present means non-empty
 *  and at most 500 chars, mirroring the RPC's own check (migration 101). */
function isValidOptionalString(value: unknown): boolean {
  if (value === undefined) return true;
  return typeof value === "string" && value.length > 0 && value.length <= 500;
}

function parseEvidence(body: unknown): DeliveryEvidenceRpc | null {
  const evidence = (body as { evidence?: unknown } | null)?.evidence;
  if (typeof evidence !== "object" || evidence === null || Array.isArray(evidence)) {
    return null;
  }

  const candidate = evidence as { mode?: unknown; wamid?: unknown; path?: unknown };
  if (
    typeof candidate.mode !== "string" ||
    !VALID_MODES.includes(candidate.mode as DeliveryEvidenceMode)
  ) {
    return null;
  }
  if (!isValidOptionalString(candidate.wamid)) return null;
  if (!isValidOptionalString(candidate.path)) return null;

  const result: DeliveryEvidenceRpc = { mode: candidate.mode as DeliveryEvidenceMode };
  if (candidate.wamid !== undefined) result.wamid = candidate.wamid as string;
  if (candidate.path !== undefined) result.path = candidate.path as string;
  return result;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
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
            "evidence must be an object with mode 'proof_sent' | 'no_proof' | 'skip_proof' and an optional non-empty wamid/path of at most 500 characters",
        },
        { status: 400 },
      );
    }

    const notify = parseNotify(body, true);
    if (notify === null) return invalidNotifyResponse();

    const { data, error } = await ctx.supabase.rpc("crm_entregar_operacion", {
      p_operation_id: operationId,
      p_evidence: evidence,
      p_notify: notify,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations deliver POST] RPC error:", error);
      throw new Error("operation delivery failed");
    }

    const payload = data as { new_status: string; completed_at: string | null };
    return NextResponse.json(
      { ok: true, newStatus: payload.new_status, completedAt: payload.completed_at },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
