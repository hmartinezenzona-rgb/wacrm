// ============================================================
// GET/POST /api/calculadora/weeks
//
// GET lists the archived Calculator weeks of the account (newest first, summaries only). POST is "Limpiar todo": the
// weekly cut (`crm_cerrar_semana_calculadora`, migrations 227 and 228) archives the draft text, the period and the entries
// shown (the bot's and the manual ones; both sets of totals are computed in SQL), records the cut and empties the document. History readers (Finanzas,
// dashboard, closes) are unaffected: no entry row changes. Runs on the CALLER'S session client; agent+ (the role that
// can save the document).
// ============================================================

import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { WEEK_SUMMARY_COLUMNS, mapWeek, mapWeekSummary, type CalculatorWeekRow } from "@/lib/calculator/weeks";

const NO_STORE = { "Cache-Control": "private, no-store" };

export async function GET() {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });

    const { data, error } = await account.supabase
      .from("remittance_calculator_weeks")
      .select(WEEK_SUMMARY_COLUMNS)
      .eq("account_id", account.accountId)
      .order("cut_at", { ascending: false })
      .limit(200);
    if (error) {
      console.error("[calculadora weeks GET] read error:", error);
      throw new Error("calculator weeks read failed");
    }

    return NextResponse.json(
      { weeks: ((data ?? []) as CalculatorWeekRow[]).map(mapWeekSummary) },
      { headers: NO_STORE },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}

export async function POST(request: Request) {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });

    const body = (await request.json().catch(() => null)) as { rawText?: unknown; periodo?: unknown } | null;
    if (!body || typeof body.rawText !== "string" || typeof body.periodo !== "string") {
      return NextResponse.json({ error: "rawText and periodo are required" }, { status: 400 });
    }

    const { data, error } = await account.supabase.rpc("crm_cerrar_semana_calculadora", {
      p_account_id: account.accountId,
      p_raw_text: body.rawText,
      p_period_label: body.periodo,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculadora weeks POST] RPC error:", error);
      throw new Error("calculator weekly cut failed");
    }

    const week = mapWeek(data as CalculatorWeekRow);
    return NextResponse.json({ week, cutAt: week.cutAt }, { headers: NO_STORE });
  } catch (error) {
    return toErrorResponse(error);
  }
}
