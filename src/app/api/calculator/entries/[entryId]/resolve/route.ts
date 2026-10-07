// ============================================================
// POST /api/calculator/entries/{entryId}/resolve
//
// Applies an admin-supplied set of rates to a `verified_pending` ledger
// entry via `crm_resolve_pending_entry`, completing it. Uses the caller's
// own SESSION Supabase client (never service role) so the RPC sees a real
// `auth.uid()`. Unlike POST /api/calculator/rates, an explicit `null`
// rate value is never accepted here -- every provided rate must resolve
// to a finite positive number, matching the RPC's own contract (a
// pending entry cannot be completed with a rate left unset).
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import {
  UUID_RE,
  isPlainObjectWithKeys,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";
import { mapLedgerEntry, type LedgerEntryRow } from "@/lib/calculator/ledger-read-model";

const MIN_REASON_LENGTH = 5;

/** The only keys `crm_resolve_pending_entry`'s `p_rates` jsonb argument
 * accepts -- same rate columns as `crm_set_calculator_rates` (minus the Zelle tiers). */
const RATE_KEYS = [
  "cup_global_rate",
  "usdt_buy_gyd",
  "usdt_sell_gyd",
  "usdt_sell_cup",
  "efectivo_usd_gyd",
  // A pending RECARGA or SALDO_MOVIL line is priced with its own USDT cost (migrations 198, 223).
  "recarga_costo_usdt",
  "saldo_costo_usdt",
] as const;

function isRateKey(key: string): key is (typeof RATE_KEYS)[number] {
  return (RATE_KEYS as readonly string[]).includes(key);
}

function parseReason(body: unknown): string | null {
  const reason = (body as { reason?: unknown } | null)?.reason;
  if (typeof reason !== "string") return null;
  const trimmed = reason.trim();
  if (trimmed.length < MIN_REASON_LENGTH) return null;
  return trimmed;
}

/** Validates the resolve rates object: non-empty, every key known, and
 * every value a finite positive number. Unlike the /rates route, an
 * explicit `null` is never valid here -- a pending entry can only be
 * resolved by supplying the rate it was missing. */
function validateResolveRates(rates: unknown): rates is Record<string, number> {
  if (!isPlainObjectWithKeys(rates)) return false;
  return Object.entries(rates).every(
    ([key, value]) =>
      isRateKey(key) && typeof value === "number" && Number.isFinite(value) && value > 0,
  );
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ entryId: string }> },
) {
  try {
    const ctx = await requireRole("admin");
    const { entryId } = await params;

    if (!UUID_RE.test(entryId)) {
      return NextResponse.json({ error: "entryId must be a UUID" }, { status: 400 });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const reason = parseReason(body);
    if (!reason) {
      return NextResponse.json(
        { error: "reason must be a string of at least 5 characters" },
        { status: 400 },
      );
    }

    const rates = (body as { rates?: unknown } | null)?.rates;
    if (!validateResolveRates(rates)) {
      return NextResponse.json(
        {
          error:
            "rates must be a non-empty object of known rate keys with finite positive numbers",
        },
        { status: 400 },
      );
    }

    const { data, error } = await ctx.supabase.rpc("crm_resolve_pending_entry", {
      p_entry_id: entryId,
      p_rates: rates,
      p_reason: reason,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[calculator entries resolve POST] RPC error:", error);
      throw new Error("calculator entry resolution failed");
    }

    return NextResponse.json(
      { entry: mapLedgerEntry(data as LedgerEntryRow) },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
