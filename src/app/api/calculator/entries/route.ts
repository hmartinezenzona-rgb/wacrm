// ============================================================
// GET /api/calculator/entries
//
// Read-only listing of the calculator ledger (`remittance_calculator_entries`)
// for structured, completed-operation-sourced rows only -- manual textarea
// entries stay on the /calculadora page's own read path. Uses the caller's
// own SESSION Supabase client (never service role), scoped by RLS to the
// caller's account. Void rows are excluded by default; pass
// `?includeVoid=true` to include them. Totals only ever sum `completed`
// rows -- see `ledgerTotals`.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  LEDGER_ENTRY_COLUMNS,
  ledgerTotals,
  mapLedgerEntry,
  type LedgerEntryRow,
} from "@/lib/calculator/ledger-read-model";

export async function GET(request: Request) {
  try {
    const ctx = await requireRole("viewer");

    const { searchParams } = new URL(request.url);
    const includeVoid = searchParams.get("includeVoid") === "true";

    let query = ctx.supabase
      .from("remittance_calculator_entries")
      .select(LEDGER_ENTRY_COLUMNS)
      .eq("account_id", ctx.accountId)
      .eq("source", "completed_operation");

    if (!includeVoid) {
      query = query.neq("status", "void");
    }

    const { data, error } = await query
      .order("entry_date", { ascending: false })
      .order("created_at", { ascending: false });
    if (error) {
      console.error("[calculator entries GET] read error:", error);
      throw new Error("calculator entries read failed");
    }

    const entries = ((data ?? []) as LedgerEntryRow[]).map(mapLedgerEntry);
    return NextResponse.json(
      { entries, totals: ledgerTotals(entries) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
