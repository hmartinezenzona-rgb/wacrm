import { NextResponse } from "next/server";

import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { supabaseAdmin } from "@/lib/flows/admin-client";

type PromoRow = {
  id: string;
  min_cup: number;
  max_cup: number | null;
  multiplicador: number | null;
  precio_gyd: number | null;
  vigente_desde: string;
  vigente_hasta: string;
  resumen: string;
  hay_precio: boolean;
};

type PromoSourceRow = Omit<PromoRow, "resumen" | "hay_precio">;

const PROMO_ID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function formatDate(value: string): string {
  const [year, month, day] = value.slice(0, 10).split("-");
  return year && month && day ? `${day}/${month}` : value;
}

function toPromoRow(row: PromoSourceRow): PromoRow {
  const max = row.max_cup ?? row.min_cup;
  const price = row.precio_gyd;
  return {
    ...row,
    resumen: `${row.min_cup}-${max} CUP x${row.multiplicador ?? "?"}, del ${formatDate(row.vigente_desde)} al ${formatDate(row.vigente_hasta)}${price == null ? " (SIN PRECIO DEFINIDO)" : ` - ${price} GYD`}`,
    hay_precio: price != null,
  };
}

/**
 * The old browser RPC is kept as the first path because it is the canonical
 * SQL implementation. The service-role fallback makes the notification
 * usable while a project has an older PostgREST grant/schema cache: the
 * browser must never need a privileged key just to see the action.
 */
async function pendingPromos(): Promise<PromoRow[]> {
  const db = supabaseAdmin();
  const { data, error } = await db.rpc("cerebro_promo_pendiente");
  if (!error && Array.isArray(data)) return data as PromoRow[];

  if (error) {
    console.warn("[promotions/etecsa] pending RPC unavailable:", error.message);
  }

  const today = new Date().toISOString().slice(0, 10);
  const { data: promos, error: promoError } = await db
    .from("promo_etecsa")
    .select("id,min_cup,max_cup,multiplicador,vigente_desde,vigente_hasta")
    .eq("estado", "detectada")
    .gte("vigente_hasta", today)
    .order("vigente_desde", { ascending: true });
  if (promoError) throw promoError;

  const rows = (promos ?? []) as Array<{
    id: string;
    min_cup: number;
    max_cup: number | null;
    multiplicador: number | null;
    vigente_desde: string;
    vigente_hasta: string;
  }>;
  if (rows.length === 0) return [];

  const mins = [...new Set(rows.map((row) => row.min_cup))];
  const { data: prices, error: priceError } = await db
    .from("precio_recarga")
    .select("min_cup,precio_gyd")
    .in("min_cup", mins);
  if (priceError) throw priceError;

  const priceByMin = new Map(
    (prices ?? []).map((row) => [Number(row.min_cup), row.precio_gyd]),
  );
  return rows.map((row) =>
    toPromoRow({ ...row, precio_gyd: priceByMin.get(row.min_cup) ?? null }),
  );
}

export async function GET() {
  try {
    // The promo is global to the business, but only an authenticated CRM
    // member may read or act on it.
    await getCurrentAccount();
    const promos = await pendingPromos();
    return NextResponse.json({ promo: promos[0] ?? null, promos });
  } catch (err) {
    return toErrorResponse(err);
  }
}

export async function POST(request: Request) {
  try {
    await getCurrentAccount();
    const body = (await request.json().catch(() => null)) as {
      action?: unknown;
      id?: unknown;
    } | null;
    const action = body?.action;
    const id = body?.id;
    if (
      (action !== "confirm" && action !== "discard") ||
      typeof id !== "string" ||
      !PROMO_ID.test(id)
    ) {
      return NextResponse.json(
        { error: "Invalid promotion action" },
        { status: 400 },
      );
    }

    const promo = (await pendingPromos()).find((row) => row.id === id);
    if (!promo) {
      return NextResponse.json(
        { error: "La promoción ya no está pendiente" },
        { status: 409 },
      );
    }
    if (action === "confirm" && !promo.hay_precio) {
      return NextResponse.json(
        { error: "Primero define el precio de esta recarga" },
        { status: 409 },
      );
    }

    const db = supabaseAdmin();
    const update =
      action === "confirm"
        ? {
            estado: "confirmada",
            confirmada_at: new Date().toISOString(),
            confirmada_por: "crm",
          }
        : {
            estado: "descartada",
            confirmada_at: null,
            confirmada_por: null,
          };
    const { data: updated, error } = await db
      .from("promo_etecsa")
      .update(update)
      .eq("id", id)
      .eq("estado", "detectada")
      .select("id")
      .maybeSingle();
    if (error) {
      console.error("[promotions/etecsa] action failed:", error);
      return NextResponse.json(
        { error: "No se pudo actualizar la promoción" },
        { status: 500 },
      );
    }
    if (!updated) {
      return NextResponse.json(
        { error: "La promoción ya no está pendiente" },
        { status: 409 },
      );
    }

    const remaining = await pendingPromos();
    return NextResponse.json({
      result: action === "confirm" ? "confirmada" : "descartada",
      promo: remaining[0] ?? null,
      promos: remaining,
    });
  } catch (err) {
    return toErrorResponse(err);
  }
}
