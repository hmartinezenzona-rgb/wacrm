import { NextResponse } from "next/server";

import { requireRole, toErrorResponse } from "@/lib/auth/account";
import { supabaseAdmin } from "@/lib/flows/admin-client";
import { parseDiasCerrados, validateDiasCerrados } from "@/lib/away-mode/validate";

// cerebro_config has RLS and no policies: service role only, behind requireRole("admin").

export async function GET() {
  try {
    await requireRole("admin");
    const { data, error } = await supabaseAdmin()
      .from("cerebro_config")
      .select("valor")
      .eq("clave", "dias_cerrados")
      .maybeSingle();
    if (error) throw new Error(`dias_cerrados read failed: ${error.message}`);
    return NextResponse.json({ dias: parseDiasCerrados(data?.valor) });
  } catch (err) {
    return toErrorResponse(err);
  }
}

export async function PUT(request: Request) {
  try {
    await requireRole("admin");

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return NextResponse.json({ error: "Cuerpo invalido" }, { status: 400 });
    }
    const parsed = validateDiasCerrados(body);
    if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

    const { error } = await supabaseAdmin()
      .from("cerebro_config")
      .upsert(
        {
          clave: "dias_cerrados",
          valor: JSON.stringify(parsed.dias),
          actualizado: new Date().toISOString(),
        },
        { onConflict: "clave" },
      );
    if (error) throw new Error(`dias_cerrados upsert failed: ${error.message}`);

    return NextResponse.json({ dias: parsed.dias });
  } catch (err) {
    return toErrorResponse(err);
  }
}
