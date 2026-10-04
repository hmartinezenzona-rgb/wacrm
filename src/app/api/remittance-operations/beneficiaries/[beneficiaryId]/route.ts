// ============================================================
// PATCH /api/remittance-operations/beneficiaries/{beneficiaryId}
//
// Applies an agent-initiated correction to a beneficiary via
// crm_corregir_beneficiario. Uses the caller's own SESSION Supabase
// client (never service role) so the RPC sees a real auth.uid(),
// same as the GET route. Gated behind the operations_panel beta flag.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  isPlainObjectWithKeys,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

// The keys crm_corregir_beneficiario knows. Which of them apply to which
// recipient type is the DB's call (22023 -> 400 below); the route only keeps
// out unknown keys and malformed address/reference/contact_phone values.
const CORRECTABLE_KEYS: ReadonlySet<string> = new Set([
  "name",
  "card_number",
  "phone",
  "zelle_account",
  "delivery_method",
  "amount",
  "currency",
  "beneficiary_type",
  "address",
  "reference",
  "contact_phone",
]);
const CONTACT_PHONE_RE = /^[0-9]{8,15}$/;

function cambiosError(cambios: Record<string, unknown>): string | null {
  for (const key of Object.keys(cambios)) {
    if (!CORRECTABLE_KEYS.has(key)) return `unknown field: ${key}`;
  }
  for (const key of ["address", "reference"]) {
    const value = cambios[key];
    if (value !== undefined && value !== null && typeof value !== "string") {
      return `${key} must be a string or null`;
    }
  }
  const contactPhone = cambios.contact_phone;
  if (
    contactPhone !== undefined &&
    contactPhone !== null &&
    !(typeof contactPhone === "string" && CONTACT_PHONE_RE.test(contactPhone))
  ) {
    return "contact_phone must be 8 to 15 digits or null";
  }
  return null;
}

export async function PATCH(
  request: Request,
  { params }: { params: Promise<{ beneficiaryId: string }> },
) {
  try {
    const ctx = await requireRole("agent");
    const { beneficiaryId } = await params;

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

    const cambios = (body as { cambios?: unknown } | null)?.cambios;
    if (!isPlainObjectWithKeys(cambios)) {
      return NextResponse.json(
        { error: "cambios must be a non-empty object" },
        { status: 400 },
      );
    }

    const invalid = cambiosError(cambios);
    if (invalid) {
      return NextResponse.json({ error: invalid }, { status: 400 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_corregir_beneficiario", {
      p_beneficiary_id: beneficiaryId,
      p_cambios: cambios,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations beneficiaries PATCH] RPC error:", error);
      throw new Error("beneficiary correction failed");
    }

    return NextResponse.json(
      { ok: true, id: data as string },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
