// ============================================================
// GET/POST /api/calculadora/weeks
//
// GET lists the archived Calculator weeks of the account (newest first, summaries only). POST is "Limpiar todo": the
// weekly cut (`crm_cerrar_semana_calculadora`, migration 227) archives the manual text, the period, the manual totals
// the page computed and the chat entries shown, records the cut and empties the document. History readers (Finanzas,
// dashboard, closes) are unaffected: no entry row changes. Runs on the CALLER'S session client; agent+ (the role that
// can save the document).
// ============================================================

import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseManualLines } from "@/lib/calculator/manual-entries";
import { WEEK_SUMMARY_COLUMNS, mapWeek, mapWeekSummary, type CalculatorWeekRow } from "@/lib/calculator/weeks";

const NO_STORE = { "Cache-Control": "private, no-store" };

function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

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

    const body = (await request.json().catch(() => null)) as {
      rawText?: unknown;
      periodo?: unknown;
      manualTotals?: { facturadoGyd?: unknown; invertidoGyd?: unknown; retornoGyd?: unknown } | null;
      manualLines?: unknown;
    } | null;
    const totals = body?.manualTotals;
    if (
      !body || typeof body.rawText !== "string" || typeof body.periodo !== "string" || !totals ||
      !finite(totals.facturadoGyd) || !finite(totals.invertidoGyd) || !finite(totals.retornoGyd)
    ) {
      return NextResponse.json(
        { error: "rawText, periodo and finite manualTotals (facturadoGyd, invertidoGyd, retornoGyd) are required" },
        { status: 400 },
      );
    }

    // Migration 228: the lines of the week being closed are synced first, so the ledger holds exactly the text that is
    // archived (the autosave may lag the textarea). The cut itself never touches the manual entries: they stay in the
    // ledger and keep counting in Finanzas. If the sync fails nothing is archived or cleared.
    if (body.manualLines !== undefined) {
      const manualLines = parseManualLines(body.manualLines);
      if (!manualLines.ok) return NextResponse.json({ error: "Invalid manual lines" }, { status: 400 });
      const { error: syncError } = await account.supabase.rpc("crm_sincronizar_entradas_manuales", {
        p_account_id: account.accountId,
        p_lineas: manualLines.lines,
      });
      if (syncError) {
        const errorResponse = rpcErrorResponse(syncError);
        if (errorResponse) return errorResponse;
        console.error("[calculadora weeks POST] manual entries sync error:", syncError);
        throw new Error("manual entries sync failed");
      }
    }

    const { data, error } = await account.supabase.rpc("crm_cerrar_semana_calculadora", {
      p_account_id: account.accountId,
      p_raw_text: body.rawText,
      p_period_label: body.periodo,
      p_manual_facturado: totals.facturadoGyd,
      p_manual_invertido: totals.invertidoGyd,
      p_manual_retorno: totals.retornoGyd,
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
