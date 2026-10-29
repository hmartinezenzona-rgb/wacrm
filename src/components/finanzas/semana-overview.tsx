"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useLocale, useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { useServiceName } from "@/hooks/use-service-name";
import type { CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { guyanaToday } from "@/lib/calculator/manual-entries";
import type { CalculatorWeek, CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { buildSemanaOverview, type DayPoint, type OverviewEntry, type PreviousWeekInput } from "@/lib/finanzas/semana-overview";
import { num, pctText } from "@/lib/finanzas/number-format";
import { cn } from "@/lib/utils";

const COMPACT = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const int = (value: number) => num(Math.round(value));
const gyd = (value: number) => `${int(value)} GYD`;
const pct = pctText;

const CARD = "min-w-0 rounded-xl border border-border bg-card p-4 text-card-foreground";

export interface SemanaOverviewViewProps {
  entries: OverviewEntry[];
  cutAt: string | null;
  /** undefined while the previous week is loading; null when there is none to compare with. */
  previous: PreviousWeekInput | null | undefined;
  rates: Pick<CalculatorRates, "usdtSellGyd" | "usdtBuyGyd" | "cupGlobalRate"> | null;
  now: Date;
  /** False until the page has loaded its entries, so an empty list is not shown as an empty week. */
  ready: boolean;
  onRegister: () => void;
  onCloseWeek: () => void;
  onShowRates: () => void;
}

function Delta({ value }: { value: number | null }) {
  const t = useTranslations("Finanzas.semana.kpi");
  if (value === null) return null;
  const rounded = Math.round(value);
  const dir = rounded > 0 ? "up" : rounded < 0 ? "down" : "flat";
  // The arrow and the word carry the direction; the colour only echoes it.
  return (
    <span className={cn("font-bold", dir === "up" && "text-money-profit", dir === "down" && "text-money-loss", dir === "flat" && "text-muted-foreground")}>
      <span aria-hidden="true">{dir === "up" ? "▲" : dir === "down" ? "▼" : "="} </span>
      <span className="sr-only">{dir === "up" ? t("sube") : dir === "down" ? t("baja") : t("igual")} </span>
      {Math.abs(rounded)} %
    </span>
  );
}

function Kpi({ label, value, profit, children }: { label: string; value: string; profit?: boolean; children?: ReactNode }) {
  return (
    <div className={cn(CARD, "flex flex-col gap-1.5")} data-testid="semana-kpi">
      <span className="text-xs font-semibold text-muted-foreground sm:text-[13px]">{label}</span>
      <span data-kpi-value className={cn("text-xl font-bold tracking-tight sm:text-2xl", profit && "text-money-profit")}>{value}</span>
      <span className="text-xs text-muted-foreground sm:text-[13px]">{children}</span>
    </div>
  );
}

function useDateLabels() {
  const locale = useLocale();
  const clean = (text: string) => text.replace(".", "");
  const at = (day: string) => new Date(`${day.slice(0, 10)}T12:00:00Z`);
  const weekdayShort = (day: string) => {
    const word = clean(new Intl.DateTimeFormat(locale, { weekday: "short", timeZone: "UTC" }).format(at(day)));
    return word.charAt(0).toUpperCase() + word.slice(1);
  };
  const longDate = (day: string) => {
    const weekday = new Intl.DateTimeFormat(locale, { weekday: "long", timeZone: "UTC" }).format(at(day));
    const rest = clean(new Intl.DateTimeFormat(locale, { day: "numeric", month: "short", timeZone: "UTC" }).format(at(day)));
    return `${weekday} ${rest}`;
  };
  const dayNumber = (day: string) => new Intl.DateTimeFormat(locale, { day: "numeric", timeZone: "UTC" }).format(at(day));
  return { weekdayShort, longDate, dayNumber };
}

const CHART_W = 640;
const CHART_H = 170;
const BASE_Y = 140;
const TOP_Y = 28;

function ProfitByDay({ days }: { days: DayPoint[] }) {
  const t = useTranslations("Finanzas.semana.dia");
  const { weekdayShort, dayNumber } = useDateLabels();
  const withDate = days.length > 7;
  const name = (d: DayPoint) => (withDate ? `${weekdayShort(d.day)} ${dayNumber(d.day)}` : weekdayShort(d.day));
  const tick = (d: DayPoint) => (d.isToday ? `${name(d)} · ${t("hoy")}` : name(d));
  const best = Math.max(...days.map((d) => d.retorno), 0);
  const slot = (CHART_W - 48) / days.length;
  const barW = Math.min(56, slot * 0.6);
  const label = (value: number) => (days.length > 8 ? COMPACT.format(value) : int(value));
  return (
    <div className={cn(CARD, "flex flex-1 basis-[420px] flex-col gap-3")} data-testid="semana-dia-card">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>
      <figure aria-label={t("aria")} className="m-0">
        <svg viewBox={`0 0 ${CHART_W} ${CHART_H}`} className="h-auto w-full" role="presentation" fill="var(--muted-foreground)" fontSize="12">
          <line x1="40" y1={BASE_Y} x2={CHART_W - 8} y2={BASE_Y} stroke="var(--border)" strokeWidth="1" />
          {days.map((d, i) => {
            const cx = 40 + slot * i + slot / 2;
            const height = best > 0 ? Math.max(d.retorno > 0 ? 2 : 0, (d.retorno / best) * (BASE_Y - TOP_Y)) : 0;
            const y = BASE_Y - height;
            return (
              <g key={d.day}>
                {height > 0 && <rect x={cx - barW / 2} y={y} width={barW} height={height} rx="4" fill="var(--chart-profit)" fillOpacity={d.isToday ? 0.45 : 1} />}
                {d.isFuture ? (
                  <text x={cx} y={BASE_Y - 8} textAnchor="middle" fontSize="11">{t("aunNo")}</text>
                ) : (
                  <>
                    <text x={cx} y={Math.max(14, y - 7)} textAnchor="middle" fill="var(--foreground)" fontWeight={d.isMax ? 700 : 600}>{label(d.retorno)}</text>
                    {d.isToday && <text x={cx} y={Math.min(BASE_Y - 6, y + 14)} textAnchor="middle" fontSize="11">{t("enCurso")}</text>}
                  </>
                )}
                <text x={cx} y={CHART_H - 8} textAnchor="middle" fill={d.isToday ? "var(--foreground)" : undefined} fontWeight={d.isToday ? 700 : 400}>{tick(d)}</text>
              </g>
            );
          })}
        </svg>
        {/* The table twin: every value the chart draws, reachable without reading the drawing. */}
        <table className="sr-only" data-testid="semana-dias">
          <thead>
            <tr><th>{t("dia")}</th><th>{t("ganancia")}</th><th>{t("opsCol")}</th></tr>
          </thead>
          <tbody>
            {days.map((d) => (
              <tr key={d.day}><td>{tick(d)}</td><td>{d.isFuture ? t("aunNo") : gyd(d.retorno)}</td><td>{d.isFuture ? "" : t("ops", { count: d.ops })}</td></tr>
            ))}
          </tbody>
        </table>
      </figure>
    </div>
  );
}

function TodayBox({ today, incomplete }: { today: { day: string; ops: number; facturado: number; retorno: number }; incomplete: number }) {
  const t = useTranslations("Finanzas.semana.hoy");
  const { longDate } = useDateLabels();
  const row = (label: string, value: string, strong?: boolean) => (
    <div className="flex items-baseline justify-between gap-3 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className={cn("font-semibold tabular-nums", strong && "text-money-profit")}>{value}</span>
    </div>
  );
  return (
    <div className={cn(CARD, "flex flex-1 basis-[300px] flex-col gap-3")} data-testid="semana-hoy">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{longDate(today.day)}</span>
      </div>
      <div className="flex flex-col gap-2.5">
        {row(t("ops"), String(today.ops))}
        {row(t("facturado"), gyd(today.facturado))}
        {row(t("ganancia"), gyd(today.retorno), true)}
        {incomplete > 0 && (
          // Neutral ground, the page's own text colour and an amber dot: the dot carries the warning, never brown text.
          <div data-warning className="flex items-start gap-2 rounded-lg bg-muted px-3 py-2.5 text-[13px] text-foreground">
            <span data-warning-dot aria-hidden="true" className="mt-1.5 size-2 shrink-0 rounded-full bg-status-attention" />
            <span>{t("incompletas", { count: incomplete })}</span>
          </div>
        )}
      </div>
    </div>
  );
}

function ProfitByServiceList({ rows }: { rows: ReturnType<typeof buildSemanaOverview>["services"] }) {
  const t = useTranslations("Finanzas.semana.servicio");
  const serviceName = useServiceName();
  const best = Math.max(...rows.map((r) => r.retorno), 0);
  return (
    <div className={cn(CARD, "flex flex-[999_1_480px] flex-col gap-3.5")}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>
      <div className="grid grid-cols-[minmax(0,6.5rem)_minmax(0,1fr)_auto_3.5rem] items-center gap-x-3 text-xs text-muted-foreground">
        <span>{t("servicio")}</span><span aria-hidden="true" /><span className="text-right">{t("ganancia")}</span><span className="text-right">{t("margen")}</span>
      </div>
      <ul aria-label={t("aria")} data-testid="semana-servicios" className="m-0 flex list-none flex-col gap-2.5 p-0">
        {rows.map((row) => (
          <li key={row.service} className="grid grid-cols-[minmax(0,6.5rem)_minmax(0,1fr)_auto_3.5rem] items-center gap-x-3 text-sm">
            <span className="truncate font-medium">{serviceName(row.service)}</span>
            <span aria-hidden="true" className="h-3.5">
              <span className="block h-full rounded-r bg-chart-profit" style={{ width: `${best > 0 ? Math.max(0, (row.retorno / best) * 100) : 0}%` }} />
            </span>
            <span className="text-right font-semibold tabular-nums">{int(row.retorno)}</span>
            <span className="text-right text-muted-foreground tabular-nums">{row.margin === null ? "—" : pct(row.margin)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function TopClients({ rows }: { rows: ReturnType<typeof buildSemanaOverview>["clients"] }) {
  const t = useTranslations("Finanzas.semana.clientes");
  return (
    <div className={cn(CARD, "flex flex-1 basis-[280px] flex-col gap-3")}>
      <div className="flex flex-col gap-0.5">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>
      <ol data-testid="semana-clientes" className="m-0 flex list-none flex-col gap-2.5 p-0 text-sm">
        {rows.map((row, index) => (
          <li key={row.name} className="flex items-baseline justify-between gap-3">
            <span className="min-w-0 truncate">
              {index + 1} · {row.name}
              <span className="ml-1.5 text-xs text-muted-foreground">{t("ops", { count: row.ops })}</span>
            </span>
            <span className="shrink-0 font-semibold tabular-nums">{gyd(row.retorno)}</span>
          </li>
        ))}
      </ol>
    </div>
  );
}

function RatesLine({ rates, onShowRates }: { rates: NonNullable<SemanaOverviewViewProps["rates"]>; onShowRates: () => void }) {
  const t = useTranslations("Finanzas.semana.tarifas");
  const item = (label: string, value: number | null | undefined, unit: string) =>
    value == null ? null : (
      <span>
        {label} <strong>{num(value, 4)} {unit}</strong>
      </span>
    );
  return (
    <div className={cn(CARD, "flex flex-wrap items-center justify-between gap-3")}>
      <div className="flex flex-col gap-0.5">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("note")}</span>
      </div>
      <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm">
        {item(t("ventaUsdt"), rates.usdtSellGyd, "GYD")}
        {item(t("costoUsdt"), rates.usdtBuyGyd, "GYD")}
        {item(t("tarifaCup"), rates.cupGlobalRate, "CUP/GYD")}
        <Button type="button" variant="outline" className="min-h-11 px-4" onClick={onShowRates}>{t("cambiar")}</Button>
      </div>
    </div>
  );
}

/** The overview with everything it needs handed in: no fetching, so it renders the same from a fixture. */
export function SemanaOverviewView({ entries, cutAt, previous, rates, now, ready, onRegister, onCloseWeek, onShowRates }: SemanaOverviewViewProps) {
  const t = useTranslations("Finanzas.semana");
  const { longDate } = useDateLabels();
  const overview = useMemo(() => buildSemanaOverview(entries, cutAt, previous ?? null, now), [entries, cutAt, previous, now]);

  if (!ready) {
    return <section aria-busy="true" aria-label={t("label")} className="mx-auto mb-4 max-w-[1100px] text-sm text-muted-foreground">{t("cargando")}</section>;
  }

  const { totals, usdt, comparison } = overview;
  const comparing = previous !== undefined;
  const subtitle = overview.startDay
    ? t(overview.fromCut ? "subtitleCut" : "subtitleFirst", { date: longDate(overview.startDay) })
    : null;

  return (
    <section aria-label={t("label")} className="mx-auto mb-4 flex max-w-[1100px] flex-col gap-3">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <p className="m-0 text-sm text-muted-foreground">{subtitle}</p>
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant="outline" className="min-h-11 px-4 font-semibold" onClick={onRegister}>{t("registrar")}</Button>
          <Button type="button" className="min-h-11 px-4 font-semibold" onClick={onCloseWeek}>{t("cerrar")}</Button>
        </div>
      </div>

      {overview.empty ? (
        <div className={cn(CARD, "flex flex-col gap-1 py-8 text-center")}>
          <h2 className="text-base font-semibold">{t("vacio.title")}</h2>
          <p className="m-0 text-sm text-muted-foreground">{t("vacio.hint")}</p>
        </div>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Kpi label={t("kpi.ganancia")} value={int(totals.retorno)} profit>
              {comparison && comparison.profitPct !== null ? (
                <><Delta value={comparison.profitPct} /> {t("kpi.vsAnterior")}</>
              ) : comparing ? (
                t("kpi.sinAnterior")
              ) : null}
            </Kpi>
            <Kpi label={t("kpi.facturado")} value={int(totals.facturado)}>
              {t("kpi.operaciones", { count: totals.ops })}
              {comparison && comparison.facturadoPct !== null && <> · <Delta value={comparison.facturadoPct} /></>}
            </Kpi>
            <Kpi label={t("kpi.invertido")} value={int(totals.invertido)}>
              {usdt ? t("kpi.usdt", { usdt: int(usdt.usdt), cost: num(usdt.avgCost, 1) }) : null}
            </Kpi>
            <Kpi label={t("kpi.margen")} value={totals.margin === null ? "—" : pct(totals.margin)}>
              {totals.ticket !== null && t("kpi.ticket", { amount: int(totals.ticket) })}
            </Kpi>
          </div>
          <p className="m-0 text-xs text-muted-foreground">{t("kpi.cifras")}</p>

          <div className="flex flex-wrap gap-3">
            <ProfitByDay days={overview.days} />
            <TodayBox today={overview.today} incomplete={overview.incomplete} />
          </div>

          <div className="flex flex-wrap gap-3">
            <ProfitByServiceList rows={overview.services} />
            <TopClients rows={overview.clients} />
          </div>
        </>
      )}

      {rates && <RatesLine rates={rates} onShowRates={onShowRates} />}
    </section>
  );
}

function useNow(): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    // Rolls the "today" bar over at midnight Guyana without a reload.
    const id = window.setInterval(() => setNow(new Date()), 60_000);
    return () => window.clearInterval(id);
  }, []);
  return now;
}

/**
 * The previous archived week, read from the same endpoints the Cierres tab uses (no API change): the newest summary is
 * the week before the open one, and the cut before it is where that week started.
 */
function usePreviousWeek(ready: boolean, cutAt: string | null): PreviousWeekInput | null | undefined {
  const [previous, setPrevious] = useState<PreviousWeekInput | null | undefined>(undefined);
  useEffect(() => {
    if (!ready) return;
    let active = true;
    (async () => {
      try {
        const list = await fetch("/api/calculadora/weeks", { cache: "no-store" });
        if (!list.ok) throw new Error("weeks read failed");
        const { weeks = [] } = (await list.json()) as { weeks?: CalculatorWeekSummary[] };
        const sorted = [...weeks].sort((a, b) => Date.parse(b.cutAt) - Date.parse(a.cutAt));
        const last = sorted[0];
        if (!last) return void (active && setPrevious(null));
        const detail = await fetch(`/api/calculadora/weeks/${last.id}`, { cache: "no-store" });
        if (!detail.ok) throw new Error("week read failed");
        const { week } = (await detail.json()) as { week: CalculatorWeek };
        const before = sorted[1];
        if (active) {
          setPrevious({
            startDay: before ? guyanaToday(new Date(before.cutAt)) : null,
            entries: (week.entries ?? []).map((e) => ({ entryDate: e.entryDate, facturadoGyd: e.facturadoGyd, retornoGyd: e.retornoGyd })),
          });
        }
      } catch {
        // No comparison is better than a wrong one.
        if (active) setPrevious(null);
      }
    })();
    return () => {
      active = false;
    };
  }, [ready, cutAt]);
  return previous;
}

export type SemanaOverviewProps = Omit<SemanaOverviewViewProps, "previous" | "now">;

export function SemanaOverview(props: SemanaOverviewProps) {
  const previous = usePreviousWeek(props.ready, props.cutAt);
  const now = useNow();
  return <SemanaOverviewView {...props} previous={previous} now={now} />;
}
