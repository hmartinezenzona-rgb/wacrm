"use client";

import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { num } from "@/lib/finanzas/number-format";

export interface CerrarSemanaProps {
  totals: { facturado: number; invertido: number; retorno: number; ops: number };
  sinTasa: number;
  pending: number;
  periodo: string;
  exportOnClose: boolean;
  clearing: boolean;
  message: string | null;
  onPeriodoChange: (value: string) => void;
  onExportOnCloseChange: (value: boolean) => void;
  onShowPending: (kind: "sinTasa" | "pending") => void;
  onExport: () => void;
  onArchive: () => void;
}

function Warning({ kind, label, link, onShow }: { kind: "sinTasa" | "pending"; label: string; link: string; onShow: () => void }) {
  return (
    // Neutral ground, the page's own text colour and an amber dot: the dot carries the warning, never brown text.
    <div data-notice={kind} className="flex items-center justify-between gap-3 rounded-lg bg-muted px-3 py-2.5 text-[13px] text-foreground">
      <span className="flex items-start gap-2">
        <span data-warning-dot aria-hidden="true" className="mt-1.5 size-2 shrink-0 rounded-full bg-amber-500" />
        <span>{label}</span>
      </span>
      <button type="button" onClick={onShow} className="shrink-0 rounded px-1 py-2 text-[13px] font-semibold underline underline-offset-2">{link}</button>
    </div>
  );
}

/** The end of the page: what the weekly cut will archive, the week's name and the cut itself (the page owns the cut and the export). */
export function CerrarSemana({ totals, sinTasa, pending, periodo, exportOnClose, clearing, message, onPeriodoChange, onExportOnCloseChange, onShowPending, onExport, onArchive }: CerrarSemanaProps) {
  const t = useTranslations("Finanzas.semana.cierre");
  const figure = (label: string, value: string) => (
    <div className="flex min-w-[120px] flex-1 flex-col gap-0.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className="text-lg font-bold tabular-nums">{value}</span>
    </div>
  );
  return (
    <section id="cerrarSemana" aria-label={t("title")} className="mx-auto mb-6 max-w-[1100px] rounded-xl border border-border bg-card p-4 text-card-foreground">
      <div className="mb-3 flex flex-col gap-0.5">
        <h2 className="text-[17px] font-bold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>

      <div data-testid="cierre-totales" className="mb-3 flex flex-wrap gap-x-6 gap-y-2">
        {figure(t("facturado"), num(totals.facturado, 2))}
        {figure(t("invertido"), num(totals.invertido, 2))}
        {figure(t("ganancia"), num(totals.retorno, 2))}
        {figure(t("operaciones"), t("ops", { count: totals.ops }))}
      </div>

      {(sinTasa > 0 || pending > 0) && (
        <div className="mb-3 flex flex-col gap-2">
          {sinTasa > 0 && <Warning kind="sinTasa" label={t("sinTasa", { count: sinTasa })} link={t("verlas")} onShow={() => onShowPending("sinTasa")} />}
          {pending > 0 && <Warning kind="pending" label={t("pendientes", { count: pending })} link={t("verlas")} onShow={() => onShowPending("pending")} />}
        </div>
      )}

      <div className="flex flex-wrap items-end gap-3">
        <div className="flex min-w-[220px] flex-1 flex-col gap-1">
          <label htmlFor="periodo" className="text-[13px] font-semibold">{t("nombre")}</label>
          <input id="periodo" placeholder={t("nombrePlaceholder")} value={periodo} onChange={(event) => onPeriodoChange(event.target.value)} className="h-11 rounded-lg border border-input bg-card px-3 text-sm outline-none focus:border-ring" />
        </div>
        <label htmlFor="exportarAlCerrar" className="flex min-h-11 items-center gap-2 text-[13px]">
          <input id="exportarAlCerrar" type="checkbox" checked={exportOnClose} onChange={(event) => onExportOnCloseChange(event.target.checked)} className="size-4" />
          {t("descargarTxt")}
        </label>
        <Button type="button" variant="outline" className="min-h-11 px-4 font-semibold" onClick={onExport}>{t("exportar")}</Button>
        <Button type="button" id="archivarSemana" className="min-h-11 px-4 font-semibold" onClick={onArchive} disabled={clearing} aria-busy={clearing}>
          {clearing ? t("archivando") : t("archivar")}
        </Button>
      </div>
      {message && <p role="status" className="mt-3 flex items-start gap-2 rounded-md bg-muted px-2.5 py-1.5 text-xs text-foreground"><span data-warning-dot aria-hidden="true" className="mt-1 size-2 shrink-0 rounded-full bg-amber-500" />{message}</p>}
    </section>
  );
}
