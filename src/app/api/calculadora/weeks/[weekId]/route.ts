// ============================================================
// GET /api/calculadora/weeks/{weekId}
//
// One archived Calculator week, read-only: the manual text, the period, the manual and chat totals and the chat
// entries that week showed. Runs on the CALLER'S session client (RLS: members of the account only); the account is
// also filtered explicitly.
// ============================================================

import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { UUID_RE } from "@/lib/remittance-operations/route-helpers";
import { WEEK_COLUMNS, mapWeek, type CalculatorWeekRow } from "@/lib/calculator/weeks";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ weekId: string }> },
) {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });
    const { weekId } = await params;
    if (!UUID_RE.test(weekId)) return NextResponse.json({ error: "weekId must be a UUID" }, { status: 400 });

    const { data, error } = await account.supabase
      .from("remittance_calculator_weeks")
      .select(WEEK_COLUMNS)
      .eq("id", weekId)
      .eq("account_id", account.accountId)
      .maybeSingle();
    if (error) {
      console.error("[calculadora weeks GET one] read error:", error);
      throw new Error("calculator week read failed");
    }
    if (!data) return NextResponse.json({ error: "Not found" }, { status: 404 });

    return NextResponse.json({ week: mapWeek(data as CalculatorWeekRow) }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
