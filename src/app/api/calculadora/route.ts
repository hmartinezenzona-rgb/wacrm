// ============================================================
// GET/POST /api/calculadora
//
// The manual calculator document (free text + period label, the draft the
// text box holds) plus the account's current rates and the entries of the
// open week: the bot's and the manual ones (migration 228). The POST saves
// the draft text ONLY; manual operations are added by POST ./entries.
//
// Reads and writes run on the CALLER'S OWN session client, never a
// service-role client. Migration 106 is what makes that possible: before
// it, 095's two tables had RLS on with no policies and grants only to
// `service_role`, so a logged-in user could not read a single row and this
// route had no choice but to hold an admin client. Keeping an unrestricted
// master key on a web server to read a rate and a block of text turned
// every bug in this process into a total compromise; now the database
// enforces the boundary itself and no such key is needed anywhere.
// ============================================================

import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { mapEntryRateSnapshot, type EntryRateSnapshotRow } from "@/lib/calculator/entry-rates";
import { mapRateVersion, type RateVersionRow } from "@/lib/calculator/ledger-read-model";
import { rpcErrorResponse } from "@/lib/remittance-operations/route-helpers";

const RATE_VERSION_COLUMNS =
  "id, account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, set_by, effective_at";

const CHAT_OPERATION_COLUMNS =
  "id,operation_id,source,status,service,customer_name,amount,amount_currency,entry_date,facturado_gyd,invertido_gyd,retorno_gyd,missing_inputs,cup_global_rate,cup_rate,usdt_buy_gyd,usdt_sell_gyd,cost_gyd,basis_gyd,sale_gyd,raw_line";

interface ChatOperationRow extends EntryRateSnapshotRow {
  id: string;
  /** Null for a manual entry (migration 228). */
  operation_id: string | null;
  source: "completed_operation" | "manual";
  status: "completed" | "verified_pending";
  service: string;
  customer_name: string | null;
  amount: number | string;
  amount_currency: string;
  entry_date: string;
  facturado_gyd: number | string | null;
  invertido_gyd: number | string | null;
  retorno_gyd: number | string | null;
  missing_inputs: string[] | null;
  /** Manual entries only (228): the typed line, which carries the rates the operation was quoted with. */
  raw_line?: string | null;
}

function toNullableNumber(value: number | string | null): number | null {
  if (value === null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function chatOperationPayload(row: ChatOperationRow) {
  return {
    id: row.id,
    operationId: row.operation_id,
    source: row.source,
    status: row.status,
    service: row.service,
    customerName: row.customer_name,
    amount: Number(row.amount),
    amountCurrency: row.amount_currency,
    entryDate: row.entry_date,
    facturadoGyd: toNullableNumber(row.facturado_gyd),
    invertidoGyd: toNullableNumber(row.invertido_gyd),
    retornoGyd: toNullableNumber(row.retorno_gyd),
    // Read straight off the stored `missing_inputs` column -- a pending
    // entry's missing rates are what was missing when it was fed into the
    // ledger (historical fact), never recomputed against today's rates.
    missingRates: row.missing_inputs ?? [],
    // The rates the entry was costed with (migration 104/199): the Editar form shows and edits the investment ones.
    ...mapEntryRateSnapshot(row),
    ...(row.source === "manual" ? { rawLine: row.raw_line ?? null } : {}),
  };
}

function documentFieldsPayload(
  document: { raw_text: string; period_label: string } | null,
  rateRow: RateVersionRow | null,
) {
  const rates = rateRow ? mapRateVersion(rateRow) : null;
  return {
    rawText: document?.raw_text ?? "",
    periodo: document?.period_label ?? "",
    tarifa: rates?.cupGlobalRate ?? null,
    compraUsdtGyd: rates?.usdtBuyGyd ?? null,
    ventaUsdtGyd: rates?.usdtSellGyd ?? null,
    ventaUsdtCup: rates?.usdtSellCup ?? null,
  };
}

export async function GET() {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });
    const db = account.supabase;
    const [
      { data, error },
      { data: rateRow, error: rateError },
      { data: chatRows, error: chatError },
      { data: cutRow, error: cutError },
    ] = await Promise.all([
        db
          .from("remittance_calculator_documents")
          .select("raw_text,period_label")
          .eq("account_id", account.accountId)
          .maybeSingle(),
        db
          .from("calculator_rate_versions")
          .select(RATE_VERSION_COLUMNS)
          .eq("account_id", account.accountId)
          .order("effective_at", { ascending: false })
          .order("id", { ascending: false })
          .limit(1)
          .maybeSingle(),
        // Migration 227: the Calculator reads the view of the entries not archived by a weekly cut ("Limpiar todo");
        // migration 228: the bot's entries and the manual ones. A pending line is never archived. History readers
        // (Finanzas, dashboard) keep reading the table.
        db
          .from("calculator_current_entries")
          .select(CHAT_OPERATION_COLUMNS)
          .eq("account_id", account.accountId)
          .neq("status", "void")
          .order("entry_date", { ascending: false })
          .order("created_at", { ascending: false }),
        db
          .from("remittance_calculator_weeks")
          .select("cut_at")
          .eq("account_id", account.accountId)
          .order("cut_at", { ascending: false })
          .limit(1)
          .maybeSingle(),
      ]);
    if (error) throw new Error("calculator document read failed");
    if (rateError) throw new Error("calculator rates read failed");
    if (chatError) throw new Error("calculator chat operations read failed");
    if (cutError) throw new Error("calculator weekly cut read failed");

    const documentFields = documentFieldsPayload(
      data as { raw_text: string; period_label: string } | null,
      rateRow as RateVersionRow | null,
    );

    const chatEntries = ((chatRows ?? []) as ChatOperationRow[]).map(chatOperationPayload);
    // Only `completed` rows ever count -- a verified_pending row (missing
    // rates, or an operation that hasn't reached completed yet) always
    // contributes zero, per AGENTS.md #11.
    const chatTotals = chatEntries.reduce(
      (totals, entry) => {
        if (entry.status !== "completed") return totals;
        return {
          facturadoGyd: totals.facturadoGyd + (entry.facturadoGyd ?? 0),
          invertidoGyd: totals.invertidoGyd + (entry.invertidoGyd ?? 0),
          retornoGyd: totals.retornoGyd + (entry.retornoGyd ?? 0),
          count: totals.count + 1,
        };
      },
      { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0, count: 0 },
    );

    return NextResponse.json(
      {
        ...documentFields,
        // The page ignores a live completed entry older than this cut (it was archived with that week).
        cutAt: (cutRow as { cut_at?: string } | null)?.cut_at ?? null,
        chatOperations: { entries: chatEntries, totals: chatTotals },
      },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}

export async function POST(request: Request) {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || typeof body.rawText !== "string" || typeof body.periodo !== "string") {
      return NextResponse.json({ error: "Invalid calculator document" }, { status: 400 });
    }

    // Rates are written only through POST /api/calculator/rates -- this
    // route persists the manual textarea document alone, through the one
    // function authorized to touch that table (agent+, migration 106).
    const { data, error } = await account.supabase.rpc("crm_guardar_documento_calculadora", {
      p_account_id: account.accountId,
      p_raw_text: body.rawText,
      p_period_label: body.periodo,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculadora POST] RPC error:", error);
      throw new Error("calculator document save failed");
    }

    const saved = data as { raw_text: string; period_label: string };

    return NextResponse.json(
      { rawText: saved.raw_text, periodo: saved.period_label },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
