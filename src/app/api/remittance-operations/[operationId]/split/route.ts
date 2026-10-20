// ============================================================
// POST /api/remittance-operations/{operationId}/split
//
// Splits the deposit of a mixed send across several services via crm_repartir_envio (migration 253). Body:
// { parts: [{ service, amountGyd }] }. The parts must add up exactly to the group's current total; the RPC creates the
// operations that are missing, locks each share like a human correction and readies the group once it is settled.
// Uses the caller's own SESSION Supabase client (never service role) so the RPC sees a real auth.uid() for its
// authorization and audit trail, same as the sibling routes. Gated behind the operations_panel beta flag and the
// "agent" role; the RPC re-checks membership and every rule on the parts (22023 comes back as a 400 with its message).
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";
import { isOperationService } from "@/lib/remittance-operations/services";

const PARTS_ERROR = "parts must be at least two { service, amountGyd } with a known service and an amount above zero";

interface SplitPart {
  servicio: string;
  monto_gyd: number;
}

/** The body's parts in the RPC's shape, or `null` when they are not at least two well-formed parts. */
function parseParts(body: unknown): SplitPart[] | null {
  const parts = (body as { parts?: unknown } | null)?.parts;
  if (!Array.isArray(parts) || parts.length < 2) return null;
  const parsed: SplitPart[] = [];
  for (const part of parts) {
    const { service, amountGyd } = (part ?? {}) as { service?: unknown; amountGyd?: unknown };
    if (!isOperationService(service)) return null;
    if (typeof amountGyd !== "number" || !Number.isFinite(amountGyd) || amountGyd <= 0) return null;
    parsed.push({ servicio: service, monto_gyd: amountGyd });
  }
  return parsed;
}

interface SplitRpcResult {
  grupo?: string;
  depositado?: number;
  saldo?: number;
  partes?: Array<{ operation_id: string; servicio: string; monto_gyd: number; creada: boolean; status: string }>;
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ operationId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { operationId } = await params;

    if (!UUID_RE.test(operationId)) {
      return NextResponse.json({ error: "operationId must be a UUID" }, { status: 400 });
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

    const parts = parseParts(body);
    if (!parts) {
      return NextResponse.json({ error: PARTS_ERROR }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_repartir_envio", {
      p_operation_id: operationId,
      p_partes: parts,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations split POST] RPC error:", error);
      throw new Error("split failed");
    }

    const summary = data as SplitRpcResult | null;
    return NextResponse.json(
      {
        ok: true,
        group: summary?.grupo ?? null,
        deposited: summary?.depositado ?? null,
        balance: summary?.saldo ?? null,
        parts: (summary?.partes ?? []).map((part) => ({
          operationId: part.operation_id,
          service: part.servicio,
          amountGyd: part.monto_gyd,
          created: part.creada,
          status: part.status,
        })),
      },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
