import { NextResponse } from "next/server";

import { getCurrentAccount, requireRole, toErrorResponse } from "@/lib/auth/account";
import { supabaseAdmin } from "@/lib/flows/admin-client";
import { validateAusenciaInput } from "@/lib/away-mode/validate";

// cerebro_config has RLS and no policies: only the service role may touch it,
// so every handler here guards access first and then uses supabaseAdmin().

async function currentAusencia() {
  const { data, error } = await supabaseAdmin().rpc("cerebro_ausencia_actual");
  if (error) throw new Error(`cerebro_ausencia_actual failed: ${error.message}`);
  return data ?? null;
}

export async function GET() {
  try {
    await getCurrentAccount();
    return NextResponse.json({ ausencia: await currentAusencia() });
  } catch (err) {
    return toErrorResponse(err);
  }
}

export async function PUT(request: Request) {
  try {
    const ctx = await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Cuerpo invalido" }, { status: 400 });
    }
    const now = new Date();
    const parsed = validateAusenciaInput(body, now);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

    const { data: profile } = await ctx.supabase
      .from("profiles")
      .select("full_name")
      .eq("user_id", ctx.userId)
      .maybeSingle();
    const por = (typeof profile?.full_name === "string" && profile.full_name.trim()) || "un admin";

    const { error } = await supabaseAdmin()
      .from("cerebro_config")
      .upsert(
        {
          clave: "ausencia",
          valor: JSON.stringify({
            hasta: parsed.hasta,
            motivo: parsed.motivo,
            por,
            desde: now.toISOString(),
          }),
          actualizado: now.toISOString(),
        },
        { onConflict: "clave" },
      );
    if (error) throw new Error(`ausencia upsert failed: ${error.message}`);

    return NextResponse.json({ ausencia: await currentAusencia() });
  } catch (err) {
    return toErrorResponse(err);
  }
}

export async function DELETE() {
  try {
    await requireRole("admin");
    const { error } = await supabaseAdmin()
      .from("cerebro_config")
      .upsert(
        { clave: "ausencia", valor: "", actualizado: new Date().toISOString() },
        { onConflict: "clave" },
      );
    if (error) throw new Error(`ausencia clear failed: ${error.message}`);
    return NextResponse.json({ ausencia: null });
  } catch (err) {
    return toErrorResponse(err);
  }
}
