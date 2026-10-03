// ============================================================
// Shared helpers for the remittance-operations panel API routes.
//
// Factored out of the read-only GET route so the write routes
// (correction and reassignment endpoints) can reuse the same UUID
// validation, operations_panel beta-flag gate, and RPC error-code
// mapping without duplicating them.
// ============================================================

import { NextResponse } from "next/server";
import type { requireRole } from "@/lib/auth/account";

type SessionContext = Awaited<ReturnType<typeof requireRole>>;
type SessionSupabaseClient = SessionContext["supabase"];

export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const OPERATIONS_PANEL_FEATURE = "operations_panel";

export async function isOperationsPanelEnabled(
  supabase: SessionSupabaseClient,
  userId: string,
): Promise<boolean> {
  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("beta_features")
    .eq("user_id", userId)
    .maybeSingle();
  if (profileError) {
    console.error("[remittance-operations] profile read error:", profileError);
    throw new Error("profile read failed");
  }
  const betaFeatures = (profile?.beta_features as string[] | null) ?? [];
  return betaFeatures.includes(OPERATIONS_PANEL_FEATURE);
}

export function rpcErrorResponse(error: {
  code?: string;
  message?: string;
}): NextResponse | null {
  if (error.code === "42501") {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 });
  }
  if (error.code === "22023") {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }
  if (error.code === "P0002") {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }
  if (error.code === "40001") {
    return NextResponse.json(
      { error: "Operation changed concurrently, retry" },
      { status: 409 },
    );
  }
  return null;
}

export function isPlainObjectWithKeys(
  v: unknown,
): v is Record<string, unknown> {
  return (
    typeof v === "object" &&
    v !== null &&
    !Array.isArray(v) &&
    Object.keys(v).length >= 1
  );
}

/** Reads the optional `notify` flag from a request body: `fallback` when it
 *  is absent, `null` (caller answers 400) when present but not a boolean. */
export function parseNotify(body: unknown, fallback: boolean): boolean | null {
  const notify = (body as { notify?: unknown } | null)?.notify;
  if (notify === undefined) return fallback;
  return typeof notify === "boolean" ? notify : null;
}

const NOTIFY_ERROR = "notify must be a boolean";

export function invalidNotifyResponse(): NextResponse {
  return NextResponse.json({ error: NOTIFY_ERROR }, { status: 400 });
}
