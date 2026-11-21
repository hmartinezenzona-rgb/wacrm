"use client";

// ============================================================
// Ficha del tablero — edición AP Suministros / Onlinefreedom.
//
// Compacta, al estilo de Pipedrive/HubSpot: lo que se ve sin abrir la
// ficha es lo que decide qué atender primero.
//   1. Empresa (título) + etiqueta URGENTE si la pidieron así.
//   2. Quién pide y por dónde llegó (WhatsApp o página).
//   3. Resumen de lo que piden ("3 productos · Válvulas").
//   4. Monto (si ya se cotizó) y cuánto lleva en la columna. Si lleva
//      demasiado, la etiqueta se pone ámbar/roja ("estancada", como el
//      "rotting" de Pipedrive): solicitud nueva sin tocar > 1 día,
//      cotización enviada sin respuesta >= 3 días.
// ============================================================

import type { Deal, PipelineStage } from "@/types";
import { Check, Globe, MessageCircle, Paperclip, X } from "lucide-react";
import { formatCurrency } from "@/lib/currency";
import { useTranslations } from "next-intl";
import { useNegocio } from "@/hooks/use-negocio";
import { columna, datoDeNotas, resumenDeNotas } from "@/lib/negocio/config";

interface DealCardProps {
  deal: Deal;
  stage: PipelineStage | null;
  onEdit: (deal: Deal) => void;
  /**
   * A delivery proof is prepared for this deal but not yet sent. It
   * lives in session memory only, so this is a transient hint — after
   * a reload the clip is gone because the draft is.
   */
  hasProof?: boolean;
  isOverlay?: boolean;
  /** Botón de un toque para pasar a la siguiente columna (lo pone el tablero). */
  footerAction?: React.ReactNode;
}

const URGENTE = /\s*·\s*URGENTE\s*$/i;

/** Lee las notas que escribe cotizacion_solicitar (migración 310). */
function resumenNotas(notes?: string | null) {
  const lineas = (notes ?? "").split("\n").map((l) => l.trim());
  const productos = lineas.filter((l) => l.startsWith("- ")).map((l) => l.slice(2));
  // "- 10 pz · Válvulas: bola 1in · marca X" → "Válvulas"
  const lineasProducto = productos
    .map((p) => {
      const sinCant = p.includes(" · ") ? p.split(" · ").slice(1).join(" · ") : p;
      return sinCant.split(":")[0].trim();
    })
    .filter(Boolean);
  const unicas = [...new Set(lineasProducto)];
  const origenTxt = lineas.find((l) => /^Llegó por /i.test(l)) ?? "";
  const origen: "whatsapp" | "web" | null = /whatsapp/i.test(origenTxt)
    ? "whatsapp"
    : /p[aá]gina/i.test(origenTxt)
      ? "web"
      : null;
  return { cuantos: productos.length, lineas: unicas, origen };
}

function diasDesde(iso?: string | null) {
  if (!iso) return null;
  const ms = Date.now() - new Date(iso).getTime();
  if (!Number.isFinite(ms) || ms < 0) return 0;
  return Math.floor(ms / 86_400_000);
}

function textoAntiguedad(dias: number, iso: string) {
  if (dias === 0) {
    const horas = Math.floor((Date.now() - new Date(iso).getTime()) / 3_600_000);
    return horas <= 0 ? "ahora" : `${horas} h`;
  }
  return `${dias} d`;
}

export function DealCard({
  deal,
  stage,
  onEdit,
  hasProof,
  isOverlay,
  footerAction,
}: DealCardProps) {
  const t = useTranslations("Pipelines.card");
  const urgente = URGENTE.test(deal.title);
  const titulo = deal.title.replace(URGENTE, "");
  const contacto = deal.contact?.name || deal.contact?.phone || t("noContact");
  const mostrarContacto = contacto !== titulo;
  const { negocio } = useNegocio();
  const { cuantos, lineas, origen } = resumenNotas(deal.notes);
  // Lo que cada negocio quiere ver en la tarjeta (negocio_config.tarjeta).
  const perfil = resumenDeNotas(deal.notes, negocio.tarjeta.resumen);
  const destacados = negocio.tarjeta.destacar
    .map((d) => ({ etiqueta: d.etiqueta, valor: datoDeNotas(deal.notes, d.clave) }))
    .filter((d) => d.valor);

  const desde = deal.etapa_desde || deal.created_at;
  const dias = diasDesde(desde);
  // Días en la columna para marcarla como estancada (negocio_config.columnas).
  const limite = columna(negocio, stage?.name).alerta_dias ?? null;
  const cerrada = deal.status === "won" || deal.status === "lost";
  const estancada = !cerrada && limite !== null && dias !== null && dias >= limite;
  const porVencer = !cerrada && !estancada && limite !== null && dias !== null && limite > 1 && dias === limite - 1;

  const valor = Number(deal.value || 0);

  return (
    <div
      role="button"
      tabIndex={-1}
      onClick={(e) => {
        // `onClick` still fires after a non-drag tap because the sensors
        // require movement / a long press before it counts as a drag.
        if (isOverlay) return;
        e.stopPropagation();
        onEdit(deal);
      }}
      className={`group w-full cursor-pointer rounded-lg border bg-card px-3 py-2.5 text-left transition-colors ${
        estancada ? "border-red-500/40" : "border-border"
      } ${isOverlay ? "shadow-xl ring-1 ring-primary/40" : "hover:border-primary/50 hover:bg-muted/40"}`}
    >
      {/* 1. Empresa + etiquetas */}
      <div className="flex items-start gap-1.5">
        <h4 className="line-clamp-2 flex-1 text-[13px] font-semibold leading-snug text-foreground">
          {titulo}
        </h4>
        {urgente && (
          <span className="shrink-0 rounded bg-red-500/15 px-1.5 py-0.5 text-[10px] font-bold tracking-wide text-red-500">
            URGENTE
          </span>
        )}
        {hasProof && (
          <Paperclip className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary" aria-label={t("proofPrepared")} />
        )}
        {deal.status === "won" && (
          <span className="inline-flex shrink-0 items-center gap-0.5 rounded bg-emerald-500/15 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-500">
            <Check className="h-3 w-3" />
            {t("won")}
          </span>
        )}
        {deal.status === "lost" && (
          <span className="inline-flex shrink-0 items-center gap-0.5 rounded bg-red-500/15 px-1.5 py-0.5 text-[10px] font-semibold text-red-500">
            <X className="h-3 w-3" />
            {t("lost")}
          </span>
        )}
      </div>

      {/* 2. Quién y por dónde */}
      {(mostrarContacto || origen) && (
        <div className="mt-1 flex items-center gap-1.5 text-xs text-muted-foreground">
          {origen === "whatsapp" && (
            <MessageCircle className="h-3 w-3 shrink-0 text-emerald-500" aria-label="Llegó por WhatsApp" />
          )}
          {origen === "web" && <Globe className="h-3 w-3 shrink-0 text-sky-500" aria-label="Llegó por la página" />}
          {mostrarContacto && <span className="truncate">{contacto}</span>}
        </div>
      )}

      {/* 3. Qué piden */}
      {cuantos > 0 && (
        <p className="mt-1 truncate text-xs text-muted-foreground/90">
          <span className="font-medium text-foreground/80">
            {cuantos} {cuantos === 1 ? "producto" : "productos"}
          </span>
          {lineas.length > 0 && <> · {lineas.slice(0, 2).join(", ")}{lineas.length > 2 ? "…" : ""}</>}
        </p>
      )}

      {cuantos === 0 && perfil && (
        <p className="mt-1 line-clamp-2 text-xs text-muted-foreground/90">{perfil}</p>
      )}
      {destacados.map((d) => (
        <p key={d.etiqueta} className="mt-1 truncate text-xs font-medium text-sky-500">
          {d.etiqueta}: {d.valor}
        </p>
      ))}

      {/* 4. Monto y tiempo en la columna */}
      <div className="mt-2 flex items-center justify-between gap-2">
        <span className={`text-[13px] font-semibold ${valor > 0 ? "text-foreground" : "text-muted-foreground/60"}`}>
          {valor > 0 ? formatCurrency(valor, deal.currency) : "Sin monto"}
        </span>
        {dias !== null && desde && (
          <span
            title={estancada ? "Lleva demasiado en esta columna" : "Tiempo en esta columna"}
            className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold tabular-nums ${
              estancada
                ? "bg-red-500/15 text-red-500"
                : porVencer
                  ? "bg-amber-500/15 text-amber-500"
                  : "bg-muted text-muted-foreground"
            }`}
          >
            {textoAntiguedad(dias, desde)}
          </span>
        )}
      </div>

      {footerAction}
    </div>
  );
}
