"use client";

import { useState, type ChangeEvent, type KeyboardEvent } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";

const HINTS = ["Pedro 150 MLC (30%/240/245)", "Carlos 1k usdt (235/260)"];

export interface QuickEntryProps {
  value: string;
  readOnly: boolean;
  registering: boolean;
  canRegister: boolean;
  onChange: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  onRegister: () => void;
}

/**
 * The "+ Línea" bar: the same text box as ever (it keeps the draft, the day headers and the bullets), shown as one line that
 * grows with what is typed, with the short format hints and the full guide of formats a click away.
 */
export function QuickEntry({ value, readOnly, registering, canRegister, onChange, onKeyDown, onRegister }: QuickEntryProps) {
  const t = useTranslations("Finanzas.semana.registros");
  const [guideOpen, setGuideOpen] = useState(false);
  const rows = Math.min(8, Math.max(1, value.split("\n").length));
  return (
    <div className="mb-3 flex flex-col gap-2">
      <div className="flex flex-wrap items-start gap-2 rounded-lg border border-border bg-muted/40 p-2">
        <span className="py-2.5 pl-1 text-sm font-semibold">{t("linea")}</span>
        <label htmlFor="rawText" className="sr-only">{t("lineaLabel")}</label>
        <textarea
          id="rawText"
          rows={rows}
          value={value}
          readOnly={readOnly}
          onChange={onChange}
          onKeyDown={onKeyDown}
          placeholder={t("placeholder")}
          className="min-h-11 min-w-0 flex-1 basis-[220px] resize-none rounded-md border border-input bg-card px-3 py-2.5 font-mono text-sm leading-snug outline-none focus:border-ring"
        />
        <Button type="button" id="registrarEntradas" className="min-h-11 px-4 font-semibold" onClick={onRegister} disabled={registering || !canRegister} aria-busy={registering}>
          {t("registrar")}
        </Button>
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
        <span>{t("formato")}: <code className="rounded bg-muted px-1 py-0.5">{t("formatoEjemplo")}</code></span>
        {HINTS.map((hint) => <code key={hint} className="rounded bg-muted px-1 py-0.5">{hint}</code>)}
        <button type="button" onClick={() => setGuideOpen(true)} className="min-h-11 px-1 font-semibold text-foreground underline underline-offset-2">{t("todosFormatos")}</button>
      </div>
      <details id="guiaFormatos" open={guideOpen} onToggle={(event) => setGuideOpen((event.currentTarget as HTMLDetailsElement).open)} className="rounded-lg border border-border bg-card px-3 py-2 text-[13px]">
        <summary className="cursor-pointer font-semibold">{t("guiaTitulo")}</summary>
        <div className="mt-2 overflow-x-auto">
          <table className="w-full min-w-[560px] border-collapse text-xs">
            <thead><tr><th className="border border-border bg-muted p-1.5 text-left">Servicio</th><th className="border border-border bg-muted p-1.5 text-left">Ejemplo</th><th className="border border-border bg-muted p-1.5 text-left">Cálculo</th></tr></thead>
            <tbody>
              <tr><td className="border border-border p-1.5"><b>CUP</b></td><td className="border border-border p-1.5"><code>• Fran 50k CUP (235/980)</code></td><td className="border border-border p-1.5">Tarifa global para venta; paréntesis para costo.</td></tr>
              <tr><td className="border border-border p-1.5"><b>Zelle / MLC / Clásica / Tropical</b></td><td className="border border-border p-1.5"><code>• Pedro 150 MLC (30%/240/245)</code><br /><code>• Julié 2.8k Zelle (3%/235/250)</code></td><td className="border border-border p-1.5">Aplica % descuento (si hay) y costo/venta en GYD.</td></tr>
              <tr><td className="border border-border p-1.5"><b>USDT</b></td><td className="border border-border p-1.5"><code>• Carlos 1k usdt (235/260)</code></td><td className="border border-border p-1.5">Costo y venta directos en GYD por USDT.</td></tr>
              <tr><td className="border border-border p-1.5"><b>Recargas Promo</b></td><td className="border border-border p-1.5"><code>• Josefa 1 rec promo (23.1/6.2k/242)</code></td><td className="border border-border p-1.5"><code>(USDT Costo / Venta GYD / Tasa USDT GYD)</code></td></tr>
              <tr><td className="border border-border p-1.5"><b>Saldo móvil</b></td><td className="border border-border p-1.5"><code>• Carlos 2 saldo movil (1.25/1k/242.21)</code></td><td className="border border-border p-1.5"><code>(USDT Costo / Venta GYD / Tasa USDT GYD)</code></td></tr>
              <tr><td className="border border-border p-1.5"><b>Servicios Directos</b></td><td className="border border-border p-1.5"><code>• Iza 1 ext visa 5k GYD</code></td><td className="border border-border p-1.5"><b>Ganancia limpia:</b> Inv = 0, Retorno = Monto.</td></tr>
            </tbody>
          </table>
          <p className="mt-2 text-xs text-muted-foreground">{t("guiaBullets")}</p>
        </div>
      </details>
    </div>
  );
}
