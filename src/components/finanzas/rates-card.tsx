"use client";

import { Check, Pencil, X } from "lucide-react";
import { useTranslations } from "next-intl";
import type { CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { num } from "@/lib/finanzas/number-format";
import { RATE_FIELDS, RATE_GROUPS, rateValueOf, ungroupedRates, type RateField, type RateGroup, type RateKey } from "@/lib/finanzas/rate-groups";
import { cn } from "@/lib/utils";
import { Notice } from "./notice";

export interface ArqDisplay {
  value: number;
  /** Provenance under the figure: ask, age and ARQ's own time, or the stale / failed notice. */
  note: string;
  /** True for a stale rate or a failed last attempt. */
  warn: boolean;
  /** "hace 5 min", shown in the row's label. */
  ageLabel: string | null;
}

export interface RatesCardProps {
  rates: CalculatorRates | null;
  fields?: ReadonlyArray<RateField>;
  groups?: ReadonlyArray<RateGroup>;
  arq: ArqDisplay | null;
  /** The rate being edited in place, or null. */
  editing: RateKey | null;
  draft: string;
  locked: boolean;
  saving: boolean;
  message: { text: string; kind: "ok" | "error" } | null;
  onStartEdit: (key: RateKey) => void;
  onDraftChange: (value: string) => void;
  onSave: () => void;
  onCancel: () => void;
}

const ROW = "grid min-h-11 w-full grid-cols-[minmax(0,1fr)_auto_1.25rem] items-center gap-2 border-b border-border";

export function RatesCard({ rates, fields = RATE_FIELDS, groups = RATE_GROUPS, arq, editing, draft, locked, saving, message, onStartEdit, onDraftChange, onSave, onCancel }: RatesCardProps) {
  const t = useTranslations("Finanzas.semana.tasas");
  const leftovers = ungroupedRates(groups, fields);
  const shown: RateGroup[] = leftovers.length
    ? [...groups, { id: "otras", title: t("otras"), rates: leftovers.map((field) => ({ key: field.key, label: field.label })) }]
    : [...groups];

  function renderRate(rate: RateGroup["rates"][number]) {
    const value = rateValueOf(rates, rate.key, fields);
    const label = (
      <span className="min-w-0 text-[13px] text-muted-foreground">
        {rate.label}
        {rate.note && <span className="block text-[11.5px] leading-tight">{rate.note}</span>}
      </span>
    );
    if (editing === rate.key) {
      const key = (event: React.KeyboardEvent<HTMLInputElement>) => {
        if (event.key === "Enter") {
          event.preventDefault();
          if (!saving) onSave();
        } else if (event.key === "Escape") {
          event.preventDefault();
          if (!saving) onCancel();
        }
      };
      return (
        <div key={rate.key} data-rate={rate.key} className={cn(ROW, "grid-cols-[minmax(0,1fr)_auto] py-1.5")}>
          {label}
          <span className="flex items-center gap-1.5">
            <input
              autoFocus
              type="number"
              step="any"
              min="0"
              inputMode="decimal"
              aria-label={t("nuevoValor", { rate: rate.label })}
              value={draft}
              disabled={saving || locked}
              onChange={(event) => onDraftChange(event.target.value)}
              onKeyDown={key}
              className="h-9 w-24 rounded-md border border-input bg-card px-2 text-right text-[15px] font-bold tabular-nums outline-none focus:border-ring"
            />
            <button type="button" aria-label={t("guardar")} title={t("guardar")} disabled={saving || locked} aria-busy={saving} onClick={onSave} className="inline-flex size-8 items-center justify-center rounded-md border border-border text-muted-foreground hover:bg-accent disabled:opacity-50">
              <Check size={16} aria-hidden="true" />
            </button>
            <button type="button" aria-label={t("cancelar")} title={t("cancelar")} disabled={saving} onClick={onCancel} className="inline-flex size-8 items-center justify-center rounded-md border border-border text-muted-foreground hover:bg-accent disabled:opacity-50">
              <X size={16} aria-hidden="true" />
            </button>
          </span>
        </div>
      );
    }
    return (
      <div key={rate.key} data-rate={rate.key} className="contents">
        <button type="button" disabled={locked || saving} onClick={() => onStartEdit(rate.key)} className={cn(ROW, "group cursor-pointer bg-transparent p-0 text-left disabled:cursor-default")}>
          {label}
          <span className="whitespace-nowrap text-right text-[15px] font-bold tabular-nums">
            {value == null ? "—" : num(value, 20)}
            {value != null && rate.unit && <small className="ml-1 text-[11px] font-medium text-muted-foreground">{rate.unit}</small>}
          </span>
          {locked ? <span aria-hidden="true" /> : <Pencil aria-hidden="true" size={14} className="text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100 motion-reduce:transition-none" />}
        </button>
      </div>
    );
  }

  return (
    <section id="tasasActuales" aria-label={t("title")} className="mx-auto mb-4 max-w-[1100px] rounded-xl border border-border bg-card p-4 text-card-foreground">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-[17px] font-bold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("hint")}</span>
      </div>
      {message && (
        <div id="tasasMensaje">
          <Notice tone={message.kind === "ok" ? "ok" : "warn"}>{message.text}</Notice>
        </div>
      )}
      <div data-testid="tasas-grupos" className="flex flex-wrap gap-3">
        {shown.map((group) => (
          <div key={group.id} data-testid="tasas-grupo" className="@container min-w-0 flex-1 basis-[230px] rounded-[10px] border border-border bg-muted/40 px-3.5 pb-2 pt-1.5">
            <h3 className="border-b border-border py-2 text-[13px] font-bold">{group.title}</h3>
            <div className="grid grid-cols-1 gap-x-7 @[520px]:grid-cols-[repeat(auto-fill,minmax(220px,1fr))]">
              {group.rates.map(renderRate)}
              {group.withArq && arq && (
                <div data-testid="tasa-arq" id="tasaMexicoArq" className="border-b border-border py-2">
                  <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2">
                    <span className="text-[13px] text-muted-foreground">{arq.ageLabel ? t("arqAuto", { age: arq.ageLabel }) : t("arqAutoSinEdad")}</span>
                    <span className="whitespace-nowrap text-[15px] font-bold tabular-nums">{num(arq.value, 6)}<small className="ml-1 text-[11px] font-medium text-muted-foreground">MXN</small></span>
                  </div>
                  {arq.warn ? <div className="mt-1"><Notice>{arq.note}</Notice></div> : arq.note ? <span className="mt-0.5 block text-[11px] text-muted-foreground">{arq.note}</span> : null}
                </div>
              )}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
