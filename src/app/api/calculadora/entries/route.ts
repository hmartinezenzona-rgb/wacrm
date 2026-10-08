// ============================================================
// POST /api/calculadora/entries
//
// "Registrar": adds the lines of the Calculator's text box as manual operations (migration 228,
// `crm_registrar_entradas_manuales`): rows of the Calculator's one table (source 'manual'), dated on the day each line
// belongs to, counted by Finanzas and the dashboard like the bot's. All lines or none. It is an ADD, not a sync: the same
// lines sent twice are added twice, so the page removes the registered lines from its box. Runs on the CALLER'S session
// client (never service role); agent+ (the role that saves the Calculator document), enforced again by the RPC.
// ============================================================

import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";
import { parseManualLines } from "@/lib/calculator/manual-entries";
import { mapRealtimeCalculatorEntry, type CalculatorEntryRealtimeRow } from "@/lib/calculator/realtime-entry";

export async function POST(request: Request) {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });

    const body = (await request.json().catch(() => null)) as { lines?: unknown } | null;
    const lines = parseManualLines(body?.lines);
    if (!lines.ok) return NextResponse.json({ error: "Invalid manual lines" }, { status: 400 });

    const { data, error } = await account.supabase.rpc("crm_registrar_entradas_manuales", {
      p_account_id: account.accountId,
      p_lineas: lines.lines,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculadora entries POST] RPC error:", error);
      throw new Error("manual entries registration failed");
    }
    if (!Array.isArray(data)) {
      console.error("[calculadora entries POST] unexpected RPC answer");
      throw new Error("manual entries registration failed");
    }

    const entries = (data as CalculatorEntryRealtimeRow[]).flatMap((row) => {
      const entry = mapRealtimeCalculatorEntry(row);
      return entry ? [entry] : [];
    });
    return NextResponse.json({ entries }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
