import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { supabaseAdmin } from "@/lib/flows/admin-client";
import { mapRateVersion, type RateVersionRow } from "@/lib/calculator/ledger-read-model";

const RATE_VERSION_COLUMNS =
  "id, account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, set_by, effective_at";

const CHAT_OPERATION_COLUMNS =
  "id,operation_id,status,service,customer_name,amount,amount_currency,entry_date,facturado_gyd,invertido_gyd,retorno_gyd,missing_inputs";

interface ChatOperationRow {
  id: string;
  operation_id: string;
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
    const db = supabaseAdmin();
    const [{ data, error }, { data: rateRow, error: rateError }, { data: chatRows, error: chatError }] =
      await Promise.all([
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
        db
          .from("remittance_calculator_entries")
          .select(CHAT_OPERATION_COLUMNS)
          .eq("account_id", account.accountId)
          .eq("source", "completed_operation")
          .neq("status", "void")
          .order("entry_date", { ascending: false })
          .order("created_at", { ascending: false }),
      ]);
    if (error) throw new Error("calculator document read failed");
    if (rateError) throw new Error("calculator rates read failed");
    if (chatError) throw new Error("calculator chat operations read failed");

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
      { ...documentFields, chatOperations: { entries: chatEntries, totals: chatTotals } },
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
    // route persists the manual textarea document alone.
    const { data, error } = await supabaseAdmin()
      .from("remittance_calculator_documents")
      .upsert(
        {
          account_id: account.accountId,
          raw_text: body.rawText,
          period_label: body.periodo,
          updated_by: account.userId,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "account_id" },
      )
      .select("raw_text,period_label")
      .single();
    if (error) throw new Error("calculator document save failed");
    return NextResponse.json(
      { rawText: data.raw_text, periodo: data.period_label },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
