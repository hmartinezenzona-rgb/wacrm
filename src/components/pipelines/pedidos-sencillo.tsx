"use client";

// ============================================================
// Pedidos en vista sencilla (negocio_config.sencillo) — celular.
//
// En vez de columnas que hay que deslizar de lado: una pestaña grande
// por paso (con cuántos hay), y cada pedido es una tarjeta con lo
// importante en grande (quién, cuántas, para cuándo, total, lo que
// lleva y la nota resaltada) y UN solo botón para pasarlo al siguiente
// paso. El texto del botón es el que el negocio puso en Ajustes
// (negocio_config.columnas). Cancelar se hace desde la ficha.
//
// Arriba, si el negocio tiene cupo diario (menu_config), cuánto lleva
// apartado mañana.
// ============================================================

import { useEffect, useMemo, useState } from "react";
import { Check, Clock, MessageCircle } from "lucide-react";
import type { Deal, PipelineStage } from "@/types";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { useNegocio } from "@/hooks/use-negocio";
import { capital, cuantas, textoBoton } from "@/lib/negocio/config";
import { diaCorto, isoLocal } from "@/lib/negocio/dias";
import { leerBloques } from "@/lib/encargos/leer";
import { formatCurrency } from "@/lib/currency";
import { cn } from "@/lib/utils";

const CERRADA = /cancel|perdid|lost/i;

/** «3 charolas · Ana» → 3 */
function unidadesDe(deal: Deal): number {
  const m = /^(\d+)\s/.exec(deal.title);
  return m ? Number(m[1]) : 1;
}

function cuando(iso: string | undefined, hoy: string, manana: string): string {
  if (!iso) return "";
  if (iso === hoy) return "para hoy";
  if (iso === manana) return "para mañana";
  if (iso < hoy) return `era para el ${diaCorto(iso)}`;
  return `para el ${diaCorto(iso)}`;
}

export function PedidosSencillo({
  stages,
  deals,
  onDealMoved,
  onEditDeal,
}: {
  stages: PipelineStage[];
  deals: Deal[];
  onDealMoved: (dealId: string, newStageId: string) => void;
  onEditDeal: (deal: Deal) => void;
}) {
  const { negocio } = useNegocio();
  const { account } = useAuth();
  const [{ hoy, manana }] = useState(() => {
    const a = new Date();
    return { hoy: isoLocal(a), manana: isoLocal(new Date(a.getTime() + 86400000)) };
  });
  const pasos = useMemo(
    () => [...stages].sort((a, b) => a.position - b.position).filter((s) => !CERRADA.test(s.name)),
    [stages],
  );
  const [elegido, setElegido] = useState<string | null>(null);
  const activo = pasos.find((s) => s.id === elegido) ?? pasos[0];
  const [cupo, setCupo] = useState<number | null>(null);

  useEffect(() => {
    if (!account?.id) return;
    let vivo = true;
    createClient()
      .from("menu_config")
      .select("cupo_diario")
      .eq("account_id", account.id)
      .maybeSingle()
      .then(({ data }) => vivo && setCupo(data ? Number(data.cupo_diario) : null));
    return () => {
      vivo = false;
    };
  }, [account?.id]);

  const idsCerradas = new Set(stages.filter((s) => CERRADA.test(s.name)).map((s) => s.id));
  const apartadasManana = deals
    .filter((d) => d.expected_close_date === manana && !idsCerradas.has(d.stage_id) && d.status !== "lost")
    .reduce((n, d) => n + unidadesDe(d), 0);

  const porPaso = (id: string) => deals.filter((d) => d.stage_id === id);
  const lista = activo
    ? porPaso(activo.id).sort((a, b) =>
        (a.expected_close_date ?? "9999").localeCompare(b.expected_close_date ?? "9999"),
      )
    : [];
  const i = activo ? pasos.findIndex((s) => s.id === activo.id) : -1;
  const siguiente = i >= 0 ? pasos[i + 1] ?? null : null;

  return (
    <div className="flex flex-col gap-4">
      {cupo !== null && cupo > 0 && (
        <section className="flex flex-col gap-2 rounded-3xl border-2 border-border bg-card p-4">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-lg font-extrabold">Mañana</span>
            <span className="text-lg font-extrabold tabular-nums">
              {apartadasManana} de {cuantas(negocio, cupo)}
            </span>
          </div>
          <div
            className="h-3.5 overflow-hidden rounded-full bg-muted"
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={cupo}
            aria-valuenow={apartadasManana}
            aria-label={`${capital(negocio.pedido.varios)} apartadas para mañana`}
          >
            <div
              className={cn("h-full rounded-full", apartadasManana >= cupo ? "bg-primary" : "bg-ok")}
              style={{ width: `${Math.min(100, (apartadasManana / cupo) * 100)}%` }}
            />
          </div>
          <span className="text-base font-semibold text-muted-foreground">
            {apartadasManana >= cupo
              ? "Ya se llenó mañana"
              : `Quedan ${cupo - apartadasManana} lugares para mañana`}
          </span>
        </section>
      )}

      <div
        role="tablist"
        aria-label="Paso del pedido"
        className="grid gap-1.5 rounded-3xl bg-muted p-1.5"
        style={{ gridTemplateColumns: `repeat(${Math.min(pasos.length, 3)}, minmax(0, 1fr))` }}
      >
        {pasos.map((s) => {
          const on = activo?.id === s.id;
          return (
            <button
              key={s.id}
              type="button"
              role="tab"
              aria-selected={on}
              onClick={() => setElegido(s.id)}
              className={cn(
                "flex min-h-16 flex-col items-center justify-center rounded-2xl px-1 text-center leading-tight",
                on ? "bg-card text-foreground shadow-sm" : "text-muted-foreground",
              )}
            >
              <span className="text-base font-extrabold">{s.name}</span>
              <span className={cn("text-xl font-extrabold tabular-nums", on && "text-primary")}>
                {porPaso(s.id).length}
              </span>
            </button>
          );
        })}
      </div>

      {lista.length === 0 && (
        <p className="rounded-3xl border-2 border-dashed border-border p-8 text-center text-lg font-semibold text-muted-foreground">
          No hay nada en «{activo?.name}»
        </p>
      )}

      {lista.map((d) => {
        const bloques = leerBloques(d.notes, negocio.pedido.uno);
        const lineas = bloques.filter((b) => b.tipo === "charola" || (b.tipo === "linea" && b.etiqueta === "Extra"));
        const nota = bloques.find((b) => b.tipo === "linea" && b.etiqueta === "Nota");
        const anticipo = bloques.find((b) => b.tipo === "dato" && /^anticipo\s*:/i.test(b.texto));
        const nombre = d.contact?.name || d.title.replace(/^\d+\s+\S+\s+·\s+/, "");
        const tel = (d.contact?.phone || "").replace(/\D/g, "");
        const atrasado = !!d.expected_close_date && d.expected_close_date < hoy;
        return (
          <article key={d.id} className="flex flex-col gap-3 rounded-3xl border-2 border-border bg-card p-4">
            <button type="button" onClick={() => onEditDeal(d)} className="flex flex-col gap-3 text-left">
              <div className="flex items-start justify-between gap-3">
                <div className="flex min-w-0 flex-col">
                  <h3 className="text-2xl font-extrabold leading-tight">{nombre}</h3>
                  <span className={cn("text-lg font-bold", atrasado ? "text-primary" : "text-muted-foreground")}>
                    {cuantas(negocio, unidadesDe(d))}
                    {d.expected_close_date ? ` · ${cuando(d.expected_close_date, hoy, manana)}` : ""}
                  </span>
                </div>
                {Number(d.value) > 0 && (
                  <span className="shrink-0 text-2xl font-extrabold tabular-nums">
                    {formatCurrency(Number(d.value), d.currency || "MXN")}
                  </span>
                )}
              </div>
              {(lineas.length > 0 || nota) && (
                <div className="flex flex-col gap-1 rounded-2xl bg-muted px-3 py-2.5">
                  {lineas.slice(0, 4).map((b, k) =>
                    b.tipo === "charola" ? (
                      <span key={k} className="text-base font-semibold leading-snug">
                        <b className="font-extrabold">{b.titulo}:</b> {b.platos.join(", ")}
                      </span>
                    ) : b.tipo === "linea" ? (
                      <span key={k} className="text-base font-semibold leading-snug">
                        <b className="font-extrabold">Extra:</b> {b.texto}
                      </span>
                    ) : null,
                  )}
                  {lineas.length > 4 && (
                    <span className="text-base font-bold text-muted-foreground">y {lineas.length - 4} más…</span>
                  )}
                  {nota && nota.tipo === "linea" && (
                    <span className="self-start rounded-lg bg-pendiente-soft px-2 py-1 text-base font-bold text-pendiente">
                      Nota: {nota.texto}
                    </span>
                  )}
                </div>
              )}
            </button>

            {i === 0 && anticipo && anticipo.tipo === "dato" && (
              <p className="flex items-center gap-2 text-base font-extrabold text-pendiente">
                <Clock className="h-5 w-5" aria-hidden />
                Falta {anticipo.texto.toLowerCase()}
              </p>
            )}

            <div className="flex gap-2.5">
              {tel.length >= 10 && (
                <a
                  href={`https://wa.me/${tel}`}
                  target="_blank"
                  rel="noreferrer"
                  aria-label={`Escribir a ${nombre} por WhatsApp`}
                  className="flex h-15 w-16 shrink-0 flex-col items-center justify-center rounded-2xl border-2 border-input text-xs font-extrabold"
                >
                  <MessageCircle className="h-6 w-6" aria-hidden />
                  Escribir
                </a>
              )}
              {siguiente ? (
                <button
                  type="button"
                  onClick={() => onDealMoved(d.id, siguiente.id)}
                  className={cn(
                    "flex min-h-15 flex-1 items-center justify-center gap-2 rounded-2xl px-3 text-lg font-extrabold active:scale-[0.98]",
                    i === 0 ? "bg-ok text-ok-foreground" : "bg-primary text-primary-foreground",
                  )}
                >
                  <Check className="h-6 w-6 shrink-0" strokeWidth={3} aria-hidden />
                  {textoBoton(negocio, siguiente.name)}
                </button>
              ) : (
                <span className="flex min-h-15 flex-1 items-center justify-center rounded-2xl bg-ok-soft text-lg font-extrabold text-ok">
                  {activo?.name}
                </span>
              )}
            </div>
          </article>
        );
      })}
    </div>
  );
}
