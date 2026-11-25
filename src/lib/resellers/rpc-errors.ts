// Error mapping for the reseller totals RPCs (migration 397).
//
// Same SQLSTATE contract as the sibling remittance routes, with one
// addition: a stale expected amount raises 40001 with the *current* total
// in the HINT, so the reset dialog can reload the amount it must confirm
// instead of guessing.

import { NextResponse } from "next/server";

export interface ResellerRpcError {
  code?: string | null;
  message?: string | null;
  hint?: string | null;
}

export type ResellerTotalField = "currentTotalGyd" | "currentGrandTotalGyd";

export function resellerRpcErrorResponse(
  error: ResellerRpcError,
  totalField: ResellerTotalField = "currentTotalGyd",
): NextResponse | null {
  if (error.code === "42501") {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 });
  }
  if (error.code === "P0002") {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }
  if (error.code === "22023") {
    return NextResponse.json(
      { error: error.message ?? "Invalid request" },
      { status: 400 },
    );
  }
  if (error.code === "40001") {
    const hinted =
      typeof error.hint === "string" && error.hint.trim() !== ""
        ? Number(error.hint)
        : Number.NaN;
    return NextResponse.json(
      {
        error: "The total changed while the dialog was open, reload and retry",
        [totalField]: Number.isFinite(hinted) ? hinted : null,
      },
      { status: 409 },
    );
  }
  return null;
}
