import { NextResponse } from "next/server";
import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canSendMessages } from "@/lib/auth/roles";
import { supabaseAdmin } from "@/lib/flows/admin-client";
import {
  missingDocumentRates,
  type CalculatorAutoCompletionService,
  type CalculatorDocumentRates,
} from "@/lib/calculator/document-rates";

const DEFAULT_RATE = 3;

const AUTO_COMPLETION_SERVICES = new Set<CalculatorAutoCompletionService>([
  "CUP",
  "ZELLE",
  "CLASICA",
  "TROPICAL",
  "USDT",
]);

function isAutoCompletionService(service: string): service is CalculatorAutoCompletionService {
  return AUTO_COMPLETION_SERVICES.has(service as CalculatorAutoCompletionService);
}

const CHAT_OPERATION_COLUMNS =
  "id,operation_id,status,service,customer_name,amount,amount_currency,entry_date,facturado_gyd,invertido_gyd,retorno_gyd";

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
}

function chatOperationPayload(row: ChatOperationRow, documentRates: CalculatorDocumentRates) {
  const missingRates =
    row.status === "verified_pending" && isAutoCompletionService(row.service)
      ? missingDocumentRates(row.service, documentRates)
      : [];
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
    // Only ever explains why a *pending* row has no snapshot yet — never a
    // recomputation. A completed row's snapshot is immutable and this list
    // is always empty for it (AGENTS.md #11: no recalcular historia).
    missingRates,
  };
}

const RATE_FIELDS = [
  { key: "compraUsdtGyd", column: "usdt_buy_gyd", label: "Compra USDT (GYD)" },
  { key: "ventaUsdtGyd", column: "usdt_sell_gyd", label: "Venta USDT/Zelle (GYD)" },
  { key: "ventaUsdtCup", column: "usdt_sell_cup", label: "Venta USDT (CUP)" },
] as const;

const INVALID_RATE = Symbol("invalid-rate");

function toNullableNumber(value: number | string | null): number | null {
  if (value === null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function parseOptionalRate(value: unknown): number | null | typeof INVALID_RATE {
  if (value === undefined || value === null) return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const numeric = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) return INVALID_RATE;
  return numeric;
}

function documentPayload(row: {
  raw_text: string;
  period_label: string;
  cup_global_rate: number | string;
  usdt_buy_gyd: number | string | null;
  usdt_sell_gyd: number | string | null;
  usdt_sell_cup: number | string | null;
}) {
  return {
    rawText: row.raw_text,
    periodo: row.period_label,
    tarifa: Number(row.cup_global_rate),
    compraUsdtGyd: toNullableNumber(row.usdt_buy_gyd),
    ventaUsdtGyd: toNullableNumber(row.usdt_sell_gyd),
    ventaUsdtCup: toNullableNumber(row.usdt_sell_cup),
  };
}

export async function GET() {
  try {
    const account = await getCurrentAccount();
    if (!canSendMessages(account.role)) return NextResponse.json({ error: "Insufficient role" }, { status: 403 });
    const db = supabaseAdmin();
    const [{ data, error }, { data: chatRows, error: chatError }] = await Promise.all([
      db
        .from("remittance_calculator_documents")
        .select("raw_text,period_label,cup_global_rate,usdt_buy_gyd,usdt_sell_gyd,usdt_sell_cup")
        .eq("account_id", account.accountId)
        .maybeSingle(),
      db
        .from("remittance_calculator_entries")
        .select(CHAT_OPERATION_COLUMNS)
        .eq("account_id", account.accountId)
        .eq("source", "completed_operation")
        .order("entry_date", { ascending: false })
        .order("created_at", { ascending: false }),
    ]);
    if (error) throw new Error("calculator document read failed");
    if (chatError) throw new Error("calculator chat operations read failed");

    const documentFields = data
      ? documentPayload(data)
      : { rawText: "", periodo: "", tarifa: DEFAULT_RATE, compraUsdtGyd: null, ventaUsdtGyd: null, ventaUsdtCup: null };
    const documentRates: CalculatorDocumentRates = {
      cupGlobalRate: documentFields.tarifa,
      usdtBuyGyd: documentFields.compraUsdtGyd,
      usdtSellGyd: documentFields.ventaUsdtGyd,
      usdtSellCup: documentFields.ventaUsdtCup,
    };

    const chatEntries = ((chatRows ?? []) as ChatOperationRow[]).map((row) =>
      chatOperationPayload(row, documentRates),
    );
    // Only `completed` rows ever count — a verified_pending row (missing
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
    const tarifa = typeof body.tarifa === "number" ? body.tarifa : Number(body.tarifa ?? DEFAULT_RATE);
    if (!Number.isFinite(tarifa) || tarifa <= 0) return NextResponse.json({ error: "La tarifa CUP global debe ser mayor que cero" }, { status: 400 });

    const rateColumns: Record<string, number | null> = {};
    for (const field of RATE_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(body, field.key)) continue;
      const parsed = parseOptionalRate(body[field.key]);
      if (parsed === INVALID_RATE) {
        return NextResponse.json({ error: `${field.label} debe ser mayor que cero` }, { status: 400 });
      }
      rateColumns[field.column] = parsed;
    }

    const { data, error } = await supabaseAdmin()
      .from("remittance_calculator_documents")
      .upsert(
        {
          account_id: account.accountId,
          raw_text: body.rawText,
          period_label: body.periodo,
          cup_global_rate: tarifa,
          ...rateColumns,
          updated_by: account.userId,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "account_id" },
      )
      .select("raw_text,period_label,cup_global_rate,usdt_buy_gyd,usdt_sell_gyd,usdt_sell_cup")
      .single();
    if (error) throw new Error("calculator document save failed");
    return NextResponse.json(documentPayload(data), { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
