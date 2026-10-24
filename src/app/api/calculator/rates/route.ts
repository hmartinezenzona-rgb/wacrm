// ============================================================
// GET/POST /api/calculator/rates
//
// Reads and writes the account's calculator rate versions
// (`calculator_rate_versions`, append-only). GET returns the newest row
// for the caller's account, or `null` when the account has never set
// rates (never a fabricated object of zeros). POST calls
// `crm_set_calculator_rates` with the caller's own SESSION Supabase
// client (never service role) so the RPC's admin check sees a real
// `auth.uid()`. Both routes require an account role: "viewer" to read,
// "admin" to write.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isPlainObjectWithKeys,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";
import { mapRateVersion, type RateVersionRow } from "@/lib/calculator/ledger-read-model";

const RATE_VERSION_COLUMNS =
  "id, account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, efectivo_usd_gyd, recarga_costo_usdt, saldo_costo_usdt, recarga_costo_usdt_500, zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000, set_by, effective_at";

/** The only keys `crm_set_calculator_rates`'s `p_rates` jsonb argument
 * accepts. Mirrors the RPC contract exactly -- an unknown key is rejected
 * here with 400 before the RPC is ever called. */
const RATE_KEYS = [
  "cup_global_rate",
  "usdt_buy_gyd",
  "usdt_sell_gyd",
  "usdt_sell_cup",
  "efectivo_usd_gyd",
  "recarga_costo_usdt",
  // Cost of one package of mobile balance in USDT (migration 223).
  "saldo_costo_usdt",
  // Cost of one recharge of the 500 CUP promotion tier in USDT (migration 242); recarga_costo_usdt is the 600 CUP tier.
  "recarga_costo_usdt_500",
  // Zelle sale price of each tier (migration 216): tiers start at 50, 1,000 and 2,000 USD.
  "zelle_sell_gyd",
  "zelle_sell_gyd_1000",
  "zelle_sell_gyd_2000",
] as const;

function isRateKey(key: string): key is (typeof RATE_KEYS)[number] {
  return (RATE_KEYS as readonly string[]).includes(key);
}

function validateRatesShape(rates: unknown): rates is Record<string, unknown> {
  if (!isPlainObjectWithKeys(rates)) return false;
  return Object.keys(rates).every(isRateKey);
}

export async function GET() {
  try {
    const ctx = await requireRole("viewer");

    const { data, error } = await ctx.supabase
      .from("calculator_rate_versions")
      .select(RATE_VERSION_COLUMNS)
      .eq("account_id", ctx.accountId)
      .order("effective_at", { ascending: false })
      .order("id", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) {
      console.error("[calculator rates GET] read error:", error);
      throw new Error("calculator rates read failed");
    }

    // ARQ's USD -> MXN rate and its last-attempt health (migrations 297/298),
    // read-only in the Calculator. A failure here must not hide the calculator
    // rates: the row simply does not render, and the page keeps working with the
    // editable rates.
    let arqRate: unknown = null;
    const { data: arqData, error: arqError } = await ctx.supabase.rpc("cerebro_tasa_usd_mxn_estado");
    if (arqError) {
      console.error("[calculator rates GET] ARQ rate read error:", arqError);
    } else {
      arqRate = arqData ?? null;
    }

    return NextResponse.json(
      { rates: data ? mapRateVersion(data as RateVersionRow) : null, arqRate },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}

export async function POST(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const rates = (body as { rates?: unknown } | null)?.rates;
    if (!validateRatesShape(rates)) {
      return NextResponse.json(
        { error: "rates must be a non-empty object of known rate keys" },
        { status: 400 },
      );
    }

    const expectedVersionIdRaw = (body as { expectedVersionId?: unknown }).expectedVersionId;
    let expectedVersionId: string | null = null;
    if (expectedVersionIdRaw !== undefined) {
      if (typeof expectedVersionIdRaw !== "string" || !UUID_RE.test(expectedVersionIdRaw)) {
        return NextResponse.json(
          { error: "expectedVersionId must be a UUID" },
          { status: 400 },
        );
      }
      expectedVersionId = expectedVersionIdRaw;
    }

    const { data, error } = await ctx.supabase.rpc("crm_set_calculator_rates", {
      p_account_id: ctx.accountId,
      p_rates: rates,
      p_expected_version_id: expectedVersionId,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculator rates POST] RPC error:", error);
      throw new Error("calculator rate update failed");
    }

    return NextResponse.json(
      { rates: mapRateVersion(data as RateVersionRow) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
