"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { AlertTriangle } from "lucide-react";
import { useLocale, useTranslations } from "next-intl";
import { Bar, BarChart, CartesianGrid, Cell, LabelList, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Button } from "@/components/ui/button";
import { useServiceName } from "@/hooks/use-service-name";
import type { CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { guyanaToday } from "@/lib/calculator/manual-entries";
import type { CalculatorWeek, CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { buildSemanaOverview, type DayPoint, type OverviewEntry, type PreviousWeekInput } from "@/lib/finanzas/semana-overview";
import { formatNumber } from "@/lib/format-number";
import { cn } from "@/lib/utils";
import { TipCard, TipRow } from "./profit-charts";

// Same chart tokens as the Cierres charts: one series, so the mark wears --chart-profit and there is no legend.
const MARK = "var(--chart-profit)";
const AXIS_TICK = { fill: "var(--muted-foreground)", fontSize: 11 };
const COMPACT = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const int = (value: number) => formatNumber(Math.round(value), { maximumFractionDigits: 0 });
const gyd = (value: number) => `${int(value)} GYD`;
const pct = (value: number) => `${formatNumber(value, { maximumFractionDigits: 1 })} %`;

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

function Kpi({ label, value, unit, hero, children }: { label: string; value: string; unit?: string; hero?: boolean; children?: ReactNode }) {
  return (
    <div className={cn(CARD, "flex flex-col gap-1.5")}>
      <span className="text-xs font-semibold text-muted-foreground sm:text-[13px]">{label}</span>
      <span className={cn("font-bold tracking-tight", hero ? "text-money-profit text-2xl sm:text-3xl" : "text-xl sm:text-2xl")}>
        {value}
        {unit && <span className="ml-1 text-xs font-medium text-muted-foreground">{unit}</span>}
      </span>
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
  return { weekdayShort, longDate };
}

function DayTooltip({ active, payload }: { active?: boolean; payload?: readonly { payload?: DayPoint & { name: string } }[] }) {
  const t = useTranslations("Finanzas.semana.dia");
  const point = payload?.[0]?.payload;
  if (!active || !point) return null;
  return (
    <TipCard title={point.name}>
      <TipRow name={t("ganancia")} value={gyd(point.retorno)} />
      <p className="text-muted-foreground">{t("ops", { count: point.ops })}</p>
    </TipCard>
  );
}

function ProfitByDay({ days }: { days: DayPoint[] }) {
  const t = useTranslations("Finanzas.semana.dia");
  const { weekdayShort } = useDateLabels();
  const data = days.map((d) => ({
    ...d,
    name: weekdayShort(d.day),
    tick: d.isToday ? `${weekdayShort(d.day)} · ${t("hoy")}` : weekdayShort(d.day),
    maxLabel: d.isMax ? COMPACT.format(d.retorno) : undefined,
  }));
  return (
    <div className={cn(CARD, "flex flex-1 basis-[420px] flex-col gap-3")}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>
      <figure aria-label={t("aria")} className="m-0">
        <div className="h-[220px] w-full min-w-0">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={data} margin={{ top: 20, right: 4, bottom: 0, left: 0 }}>
              <CartesianGrid vertical={false} stroke="var(--border)" strokeWidth={1} />
              <XAxis dataKey="tick" tick={AXIS_TICK} tickLine={false} axisLine={false} interval={0} />
              <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} width={40} tickFormatter={(v: number) => COMPACT.format(v)} />
              <Tooltip cursor={{ fill: "var(--muted)", opacity: 0.5 }} content={(props) => <DayTooltip {...props} />} />
              <Bar dataKey="retorno" maxBarSize={24} radius={[4, 4, 0, 0]} isAnimationActive={false}>
                {data.map((d) => (
                  <Cell key={d.day} fill={MARK} fillOpacity={d.isToday ? 0.45 : 1} />
                ))}
                <LabelList dataKey="maxLabel" position="top" fill="var(--foreground)" fontSize={12} fontWeight={600} />
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
        {/* The table twin: every value the chart draws, reachable without hovering. */}
        <table className="sr-only" data-testid="semana-dias">
          <thead>
            <tr><th>{t("dia")}</th><th>{t("ganancia")}</th><th>{t("opsCol")}</th></tr>
          </thead>
          <tbody>
            {data.map((d) => (
              <tr key={d.day}><td>{d.tick}</td><td>{gyd(d.retorno)}</td><td>{t("ops", { count: d.ops })}</td></tr>
            ))}
          </tbody>
        </table>
      </figure>
    </div>
  );
}

function TodayBox({ today, incomplete }: { today: { ops: number; facturado: number; retorno: number }; incomplete: number }) {
  const t = useTranslations("Finanzas.semana.hoy");
  const row = (label: string, value: string, strong?: boolean) => (
    <div className="flex items-baseline justify-between gap-3 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className={cn("font-semibold", strong && "text-money-profit")}>{value}</span>
    </div>
  );
  return (
    <div className={cn(CARD, "flex flex-1 basis-[300px] flex-col gap-3")} data-testid="semana-hoy">
      <h2 className="text-base font-semibold">{t("title")}</h2>
      <div className="flex flex-col gap-2.5">
        {row(t("ops"), String(today.ops))}
        {row(t("facturado"), gyd(today.facturado))}
        {row(t("ganancia"), gyd(today.retorno), true)}
        {incomplete > 0 && (
          <div className="flex items-start gap-2 rounded-lg bg-status-attention-soft px-3 py-2.5 text-[13px] text-status-attention">
            <AlertTriangle aria-hidden="true" className="mt-0.5 size-4 shrink-0" />
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
        {label} <strong>{formatNumber(value, { maximumFractionDigits: 4 })} {unit}</strong>
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
            <Kpi label={t("kpi.ganancia")} value={int(totals.retorno)} unit="GYD" hero>
              {comparison && comparison.profitPct !== null ? (
                <><Delta value={comparison.profitPct} /> {t("kpi.vsAnterior")}</>
              ) : comparing ? (
                t("kpi.sinAnterior")
              ) : null}
            </Kpi>
            <Kpi label={t("kpi.facturado")} value={int(totals.facturado)} unit="GYD">
              {t("kpi.operaciones", { count: totals.ops })}
              {comparison && comparison.facturadoPct !== null && <> · <Delta value={comparison.facturadoPct} /></>}
            </Kpi>
            <Kpi label={t("kpi.invertido")} value={int(totals.invertido)} unit="GYD">
              {usdt ? t("kpi.usdt", { usdt: int(usdt.usdt), cost: formatNumber(usdt.avgCost, { maximumFractionDigits: 1 }) }) : null}
            </Kpi>
            <Kpi label={t("kpi.margen")} value={totals.margin === null ? "—" : pct(totals.margin)}>
              {totals.ticket !== null && t("kpi.ticket", { amount: gyd(totals.ticket) })}
            </Kpi>
          </div>

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
