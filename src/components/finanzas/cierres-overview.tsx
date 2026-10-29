"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ChevronDown } from "lucide-react";
import { useLocale, useTranslations } from "next-intl";
import { Bar, BarChart, CartesianGrid, Cell, LabelList, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { FinancialCloseSection } from "@/components/resumen/financial-close-section";
import { Button } from "@/components/ui/button";
import { useServiceName } from "@/hooks/use-service-name";
import type { CalculatorWeek, CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { guyanaToday } from "@/lib/calculator/manual-entries";
import {
  buildCierresOverview,
  buildClosedWeeks,
  filterWeeksByPeriod,
  type CierresPeriod,
  type ClosedWeek,
  type ClosedWeekInput,
} from "@/lib/finanzas/cierres-overview";
import { num, pctText } from "@/lib/finanzas/number-format";
import { cn } from "@/lib/utils";
import { ArchivedWeekDetail } from "./archived-weeks";
import { TipCard, TipRow } from "./profit-charts";

// One series, so no legend; the mark wears --chart-profit and every text uses a text token.
const MARK = "var(--chart-profit)";
const AXIS_TICK = { fill: "var(--muted-foreground)", fontSize: 11 };
const COMPACT = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const int = (value: number) => num(Math.round(value));
const gyd = (value: number) => `${int(value)} GYD`;
const pct = pctText;
const CARD = "min-w-0 rounded-xl border border-border bg-card p-4 text-card-foreground";
const PERIODS: CierresPeriod[] = ["last12", "thisMonth", "lastMonth", "all"];
const COLLAPSED_ROWS = 6;
/** The overview reads the detail of at most this many (newest) weeks, a few at a time. */
const MAX_WEEKS = 60;
const BATCH = 6;

function useDayLabels() {
  const locale = useLocale();
  const clean = (text: string) => text.replace(".", "");
  const at = (day: string) => new Date(`${day.slice(0, 10)}T12:00:00Z`);
  const month = (day: string) => clean(new Intl.DateTimeFormat(locale, { month: "short", timeZone: "UTC" }).format(at(day)));
  const shortDay = (day: string) => `${at(day).getUTCDate()} ${month(day)}`;
  const weekdayShort = (day: string) => {
    const word = clean(new Intl.DateTimeFormat(locale, { weekday: "short", timeZone: "UTC" }).format(at(day)));
    return word.charAt(0).toUpperCase() + word.slice(1);
  };
  /** "20–25 oct" within a month, "29 sep – 4 oct" across two. */
  const range = (from: string, to: string) => {
    if (from === to) return shortDay(to);
    if (month(from) === month(to)) return `${at(from).getUTCDate()}–${shortDay(to)}`;
    return `${shortDay(from)} – ${shortDay(to)}`;
  };
  return { shortDay, weekdayShort, range };
}

function Delta({ value }: { value: number | null }) {
  const t = useTranslations("Finanzas.cierres.kpi");
  if (value === null) return null;
  const dir = Math.round(value * 10) > 0 ? "up" : Math.round(value * 10) < 0 ? "down" : "flat";
  // The arrow and the word carry the direction; the colour only echoes it.
  return (
    <span className={cn("font-bold", dir === "up" && "text-money-profit", dir === "down" && "text-money-loss", dir === "flat" && "text-muted-foreground")}>
      <span aria-hidden="true">{dir === "up" ? "▲" : dir === "down" ? "▼" : "="} </span>
      <span className="sr-only">{dir === "up" ? t("sube") : dir === "down" ? t("baja") : t("igual")} </span>
      {pct(Math.abs(value))}
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

interface ChartDatum {
  id: string;
  tick: string;
  retorno: number;
  selected: boolean;
  label?: string;
  name: string;
  facturado: number;
  ops: number | null;
}

function WeekTooltip({ active, payload }: { active?: boolean; payload?: readonly { payload?: ChartDatum }[] }) {
  const t = useTranslations("Finanzas.cierres.grafico");
  const point = payload?.[0]?.payload;
  if (!active || !point) return null;
  return (
    <TipCard title={`${point.name} · ${point.tick}`}>
      <TipRow name={t("ganancia")} value={gyd(point.retorno)} />
      <TipRow name={t("facturado")} value={gyd(point.facturado)} />
      {point.ops !== null && <p className="text-muted-foreground">{t("ops", { count: point.ops })}</p>}
    </TipCard>
  );
}

function WeeksChart({ chart, weeks, average, selectedId, onSelect }: {
  chart: { id: string; endDay: string; retorno: number }[];
  weeks: ClosedWeek[];
  average: number;
  selectedId: string;
  onSelect: (id: string) => void;
}) {
  const t = useTranslations("Finanzas.cierres.grafico");
  const { shortDay } = useDayLabels();
  const byId = new Map(weeks.map((w) => [w.id, w]));
  const data: ChartDatum[] = chart.map((p) => {
    const week = byId.get(p.id)!;
    return {
      id: p.id,
      tick: shortDay(p.endDay),
      retorno: p.retorno,
      selected: p.id === selectedId,
      label: p.id === selectedId ? COMPACT.format(p.retorno) : undefined,
      name: week.name,
      facturado: week.facturado,
      ops: week.ops,
    };
  });
  return (
    <div className={cn(CARD, "flex flex-col gap-3")}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>
      <figure aria-label={t("aria", { count: data.length })} className="m-0">
        <div className="h-[250px] w-full min-w-0">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={data} margin={{ top: 22, right: 8, bottom: 0, left: 0 }}>
              <CartesianGrid vertical={false} stroke="var(--border)" strokeWidth={1} />
              <XAxis dataKey="tick" tick={AXIS_TICK} tickLine={false} axisLine={false} interval="preserveStartEnd" minTickGap={10} />
              <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} width={44} tickFormatter={(v: number) => COMPACT.format(v)} />
              <ReferenceLine y={0} stroke="var(--border)" strokeWidth={1} />
              <Tooltip cursor={{ fill: "var(--muted)", opacity: 0.5 }} content={(props) => <WeekTooltip {...props} />} />
              <ReferenceLine
                y={average}
                stroke="var(--foreground)"
                strokeWidth={1.5}
                strokeDasharray="5 4"
                label={{ value: t("media", { amount: COMPACT.format(average) }), position: "insideTopLeft", fill: "var(--foreground)", fontSize: 11, fontWeight: 600 }}
              />
              <Bar dataKey="retorno" maxBarSize={36} radius={[4, 4, 0, 0]} isAnimationActive={false} cursor="pointer" onClick={(_, index) => { const d = data[index]; if (d) onSelect(d.id); }}>
                {data.map((d) => (
                  <Cell key={d.id} fill={MARK} fillOpacity={d.selected ? 1 : 0.55} />
                ))}
                <LabelList dataKey="label" position="top" fill="var(--foreground)" fontSize={12} fontWeight={700} />
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      </figure>
    </div>
  );
}

function weekDates(week: ClosedWeek, range: (from: string, to: string) => string, shortDay: (d: string) => string, none: string): string {
  if (week.startDay) return range(week.startDay, week.endDay);
  return week.ops === 0 ? none : shortDay(week.endDay);
}

function SelectedWeek({ week, opening, onOpen }: { week: ClosedWeek; opening: boolean; onOpen: () => void }) {
  const t = useTranslations("Finanzas.cierres.sel");
  const serviceName = useServiceName();
  const { range, shortDay, weekdayShort } = useDayLabels();
  const row = (label: string, value: string) => (
    <div className="flex items-baseline justify-between gap-2 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right font-semibold">{value}</span>
    </div>
  );
  return (
    <div className={cn(CARD, "flex flex-1 basis-[380px] flex-col gap-3.5")} data-testid="cierres-seleccion">
      <div className="flex flex-col gap-0.5">
        <span className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{t("eyebrow")}</span>
        <h2 className="text-lg font-bold">{week.name || "—"}</h2>
        <span className="text-[13px] text-muted-foreground">{weekDates(week, range, shortDay, t("sinFechas"))}</span>
      </div>
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <span className="text-2xl font-bold tracking-tight text-money-profit sm:text-3xl">{gyd(week.retorno)}</span>
        {week.vsPrevious !== null && (
          <span className="text-[13px]"><Delta value={week.vsPrevious} /> {t("vsAnterior")}</span>
        )}
      </div>
      <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2 sm:gap-x-4">
        {row(t("facturado"), gyd(week.facturado))}
        {row(t("invertido"), gyd(week.invertido))}
        {row(t("margen"), week.margin === null ? "—" : pct(week.margin))}
        {row(t("ops"), week.ops === null ? "—" : String(week.ops))}
        {row(t("mejorDia"), week.bestDay ? `${weekdayShort(week.bestDay.day)} · ${gyd(week.bestDay.retorno)}` : "—")}
        {row(t("servicioLider"), week.topService ? serviceName(week.topService) : "—")}
      </div>
      <div className="flex flex-wrap gap-2">
        <Button type="button" className="min-h-11 px-4 font-semibold" onClick={onOpen} disabled={opening}>{t("verRegistros")}</Button>
      </div>
    </div>
  );
}

function ProfitByService({ rows, weekCount }: { rows: ReturnType<typeof buildCierresOverview>["services"]; weekCount: number }) {
  const t = useTranslations("Finanzas.cierres.servicios");
  const serviceName = useServiceName();
  const best = Math.max(...rows.map((r) => r.retorno), 0);
  return (
    <div className={cn(CARD, "flex flex-[999_1_460px] flex-col gap-3.5")}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        <span className="text-[13px] text-muted-foreground">{t("subtitle", { count: weekCount })}</span>
      </div>
      {rows.length === 0 ? (
        <p className="m-0 text-sm text-muted-foreground">{t("vacio")}</p>
      ) : (
        <>
          <ul aria-label={t("aria")} data-testid="cierres-servicios" className="m-0 flex list-none flex-col gap-2.5 p-0">
            {rows.map((row) => (
              <li key={row.service} className="grid grid-cols-[minmax(0,6.5rem)_minmax(0,1fr)_auto_3rem] items-center gap-x-3 text-sm">
                <span className="truncate font-medium">{serviceName(row.service)}</span>
                <span aria-hidden="true" className="h-3.5">
                  <span className="block h-full rounded-r bg-chart-profit" style={{ width: `${best > 0 ? Math.max(0, (row.retorno / best) * 100) : 0}%` }} />
                </span>
                <span className="text-right font-semibold tabular-nums">{int(row.retorno)}</span>
                <span className="text-right text-muted-foreground tabular-nums">{row.share === null ? "—" : pct(row.share)}</span>
              </li>
            ))}
          </ul>
          <p className="m-0 text-[13px] text-muted-foreground">{t("nota")}</p>
        </>
      )}
    </div>
  );
}

function WeeksTable({ weeks, selectedId, onSelect }: { weeks: ClosedWeek[]; selectedId: string; onSelect: (id: string) => void }) {
  const t = useTranslations("Finanzas.cierres.tabla");
  const ts = useTranslations("Finanzas.cierres.sel");
  const { range, shortDay } = useDayLabels();
  const [expanded, setExpanded] = useState(false);
  const shown = expanded ? weeks : weeks.slice(0, COLLAPSED_ROWS);
  const th = "px-2.5 py-2 text-right text-xs font-semibold text-muted-foreground";
  const td = "px-2.5 py-2.5 text-right tabular-nums";
  return (
    <div className={cn(CARD, "flex flex-col gap-3")}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-base font-semibold">{t("title")}</h2>
        {weeks.length > COLLAPSED_ROWS && (
          <Button type="button" variant="link" className="min-h-11 px-2 font-semibold" aria-expanded={expanded} onClick={() => setExpanded((v) => !v)}>
            {expanded ? t("verMenos") : t("verTodas", { count: weeks.length })}
          </Button>
        )}
      </div>
      <div className="overflow-x-auto">
        <table aria-label={t("aria")} data-testid="cierres-tabla" className="w-full min-w-[640px] border-collapse text-sm">
          <thead>
            <tr className="border-b border-border">
              <th scope="col" className="px-2.5 py-2 text-left text-xs font-semibold text-muted-foreground">{t("semana")}</th>
              <th scope="col" className={th}>{t("ops")}</th>
              <th scope="col" className={th}>{t("facturado")}</th>
              <th scope="col" className={th}>{t("ganancia")}</th>
              <th scope="col" className={th}>{t("margen")}</th>
              <th scope="col" className={th}>{t("vsAnterior")}</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((week) => {
              const selected = week.id === selectedId;
              return (
                <tr key={week.id} onClick={() => onSelect(week.id)} className={cn("cursor-pointer border-b border-border/60 last:border-0 hover:bg-muted/50", selected && "bg-muted")}>
                  <td className="px-2.5 py-2 text-left">
                    <button type="button" aria-pressed={selected} onClick={(e) => { e.stopPropagation(); onSelect(week.id); }} className="block min-h-11 text-left">
                      <span className="block font-semibold">{week.name || "—"}</span>
                      <span className="block text-xs text-muted-foreground">{weekDates(week, range, shortDay, ts("sinFechas"))}</span>
                    </button>
                  </td>
                  <td className={td}>{week.ops === null ? "—" : week.ops}</td>
                  <td className={td}>{int(week.facturado)}</td>
                  <td className={cn(td, "font-semibold", week.retorno > 0 && "text-money-profit", week.retorno < 0 && "text-money-loss")}>{int(week.retorno)}</td>
                  <td className={td}>{week.margin === null ? "—" : pct(week.margin)}</td>
                  <td className={td}>{week.vsPrevious === null ? "—" : <Delta value={week.vsPrevious} />}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function PeriodClose() {
  const t = useTranslations("Finanzas.cierres.cuadrar");
  const [open, setOpen] = useState(false);
  return (
    <div className={cn(CARD, "flex flex-col gap-3")}>
      <div className="flex flex-col gap-0.5">
        <button type="button" aria-expanded={open} aria-controls="cierres-cuadrar" onClick={() => setOpen((v) => !v)} className="flex min-h-11 items-center gap-2 text-left text-base font-semibold">
          <ChevronDown aria-hidden="true" className={cn("size-4 shrink-0 transition-transform", !open && "-rotate-90")} />
          {t("title")}
        </button>
        <span className="text-[13px] text-muted-foreground">{t("subtitle")}</span>
      </div>
      <div id="cierres-cuadrar" hidden={!open}>
        {open && <FinancialCloseSection />}
      </div>
    </div>
  );
}

type LoadState =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; summaries: CalculatorWeekSummary[]; details: Record<string, CalculatorWeek> };

/**
 * The archived weeks and the detail of each (newest {@link MAX_WEEKS}), from the two read-only endpoints the weekly
 * cut already had. A closed week never changes, so a detail is read once; the list is read again every time the tab
 * turns active, so a cut made in the Semana tab shows up. A detail that fails is left out and its week keeps its totals.
 */
function useArchivedWeeks(active: boolean) {
  const cache = useRef(new Map<string, CalculatorWeek>());
  const [state, setState] = useState<LoadState>({ status: "loading" });
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (!active) return;
    let current = true;
    void (async () => {
      try {
        const response = await fetch("/api/calculadora/weeks", { cache: "no-store" });
        if (!response.ok) throw new Error("weeks read failed");
        const { weeks = [] } = (await response.json()) as { weeks?: CalculatorWeekSummary[] };
        const summaries = [...weeks].sort((a, b) => Date.parse(b.cutAt) - Date.parse(a.cutAt)).slice(0, MAX_WEEKS);
        const missing = summaries.filter((w) => !cache.current.has(w.id));
        for (let i = 0; i < missing.length; i += BATCH) {
          await Promise.all(
            missing.slice(i, i + BATCH).map(async (w) => {
              try {
                const detail = await fetch(`/api/calculadora/weeks/${w.id}`, { cache: "no-store" });
                if (!detail.ok) return;
                const { week } = (await detail.json()) as { week?: CalculatorWeek };
                if (week) cache.current.set(w.id, week);
              } catch {
                /* the week keeps its totals */
              }
            }),
          );
          if (!current) return;
        }
        if (current) setState({ status: "ready", summaries, details: Object.fromEntries(cache.current) });
      } catch {
        if (current) setState((previous) => (previous.status === "ready" ? previous : { status: "error" }));
      }
    })();
    return () => {
      current = false;
    };
  }, [active, attempt]);

  const retry = useCallback(() => {
    setState({ status: "loading" });
    setAttempt((n) => n + 1);
  }, []);
  return { state, retry };
}

function useToday(): string {
  const [today, setToday] = useState(() => guyanaToday(new Date()));
  useEffect(() => {
    const id = window.setInterval(() => setToday(guyanaToday(new Date())), 60_000);
    return () => window.clearInterval(id);
  }, []);
  return today;
}

/** The redesigned Cierres tab body. `active` is false while the tab is hidden but kept mounted. */
export function CierresOverview({ active = true }: { active?: boolean }) {
  const t = useTranslations("Finanzas.cierres");
  const { state, retry } = useArchivedWeeks(active);
  const today = useToday();
  const [period, setPeriod] = useState<CierresPeriod>("last12");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [openWeek, setOpenWeek] = useState<CalculatorWeek | null>(null);
  const [opening, setOpening] = useState(false);
  const [openMessage, setOpenMessage] = useState<string | null>(null);

  const allWeeks = useMemo(() => {
    if (state.status !== "ready") return [];
    const inputs: ClosedWeekInput[] = state.summaries.map((s) => ({
      id: s.id,
      cutAt: s.cutAt,
      periodo: s.periodo,
      facturado: s.manualTotals.facturadoGyd + s.chatTotals.facturadoGyd,
      invertido: s.manualTotals.invertidoGyd + s.chatTotals.invertidoGyd,
      retorno: s.manualTotals.retornoGyd + s.chatTotals.retornoGyd,
      entries: state.details[s.id]?.entries ?? null,
    }));
    return buildClosedWeeks(inputs);
  }, [state]);
  const weeks = useMemo(() => filterWeeksByPeriod(allWeeks, period, today), [allWeeks, period, today]);
  const overview = useMemo(() => buildCierresOverview(weeks), [weeks]);
  const selected = weeks.find((w) => w.id === selectedId) ?? weeks[0] ?? null;

  async function openRecords(week: ClosedWeek) {
    setOpenMessage(null);
    const stored = state.status === "ready" ? state.details[week.id] : undefined;
    if (stored) return setOpenWeek(stored);
    setOpening(true);
    try {
      const response = await fetch(`/api/calculadora/weeks/${week.id}`, { cache: "no-store" });
      if (!response.ok) throw new Error("week read failed");
      const data = (await response.json()) as { week: CalculatorWeek };
      setOpenWeek(data.week);
    } catch {
      setOpenMessage(t("sel.abrirError"));
    } finally {
      setOpening(false);
    }
  }

  if (state.status === "loading") {
    return <section aria-busy="true" aria-label={t("label")} className="text-sm text-muted-foreground">{t("cargando")}</section>;
  }
  if (state.status === "error") {
    return (
      <section aria-label={t("label")} className={cn(CARD, "flex flex-wrap items-center justify-between gap-3 border-destructive/40")}>
        <p className="m-0 text-sm text-destructive">{t("error")}</p>
        <Button type="button" variant="outline" className="min-h-11 px-4" onClick={retry}>{t("reintentar")}</Button>
      </section>
    );
  }

  const kpiTitle = period === "last12" ? t("kpi.gananciaLast12", { count: overview.count }) : t(`kpi.ganancia${period === "thisMonth" ? "ThisMonth" : period === "lastMonth" ? "LastMonth" : "All"}`);

  return (
    <section aria-label={t("label")} className="flex flex-col gap-3">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <p className="m-0 text-sm text-muted-foreground">{t("subtitle")}</p>
        <div role="group" aria-label={t("periodo.label")} className="flex flex-wrap gap-1.5">
          {PERIODS.map((key) => (
            <button
              key={key}
              type="button"
              aria-pressed={period === key}
              onClick={() => setPeriod(key)}
              className={cn(
                "min-h-11 rounded-full border px-3.5 text-sm",
                period === key ? "border-foreground bg-foreground font-semibold text-background" : "border-border bg-card font-medium text-foreground",
              )}
            >
              {t(`periodo.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {allWeeks.length === 0 ? (
        <div className={cn(CARD, "flex flex-col gap-1 py-8 text-center")}>
          <h2 className="text-base font-semibold">{t("vacio.title")}</h2>
          <p className="m-0 text-sm text-muted-foreground">{t("vacio.hint")}</p>
        </div>
      ) : weeks.length === 0 || !selected ? (
        <div className={cn(CARD, "py-6 text-center text-sm text-muted-foreground")}>{t("sinPeriodo")}</div>
      ) : (
        <Body
          overview={overview}
          weeks={weeks}
          kpiTitle={kpiTitle}
          selected={selected}
          onSelect={setSelectedId}
          opening={opening}
          onOpen={() => void openRecords(selected)}
        />
      )}

      {openMessage && <p role="alert" className="m-0 text-sm text-destructive">{openMessage}</p>}
      {openWeek && <ArchivedWeekDetail week={openWeek} onClose={() => setOpenWeek(null)} />}

      <PeriodClose />
    </section>
  );
}

function Body({ overview, weeks, kpiTitle, selected, onSelect, opening, onOpen }: {
  overview: ReturnType<typeof buildCierresOverview>;
  weeks: ClosedWeek[];
  kpiTitle: string;
  selected: ClosedWeek;
  onSelect: (id: string) => void;
  opening: boolean;
  onOpen: () => void;
}) {
  const t = useTranslations("Finanzas.cierres");
  const { shortDay } = useDayLabels();
  const { best, worst, change } = overview;
  return (
    <>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi label={kpiTitle} value={int(overview.totals.retorno)} unit="GYD" hero>
          {change && <><Delta value={change.pct} /> {t("kpi.cambio", { weeks: change.weeks })}</>}
        </Kpi>
        <Kpi label={t("kpi.promedio")} value={int(overview.avgProfit ?? 0)} unit="GYD">
          {overview.avgOps !== null && t("kpi.opsSemana", { count: Math.round(overview.avgOps) })}
        </Kpi>
        <Kpi label={t("kpi.mejorPeor")} value={best ? int(best.retorno) : "—"} unit="GYD">
          {best && t("kpi.mejor", { date: shortDay(best.endDay) })}
          {worst && <> · {t("kpi.peor", { amount: int(worst.retorno), date: shortDay(worst.endDay) })}</>}
        </Kpi>
        <Kpi label={t("kpi.margen")} value={overview.margin === null ? "—" : pct(overview.margin)}>
          {t("kpi.facturado", { amount: int(overview.totals.facturado) })}
        </Kpi>
      </div>

      {overview.chart.length > 1 && overview.average !== null ? (
        <WeeksChart chart={overview.chart} weeks={weeks} average={overview.average} selectedId={selected.id} onSelect={onSelect} />
      ) : (
        <div className={cn(CARD, "text-sm text-muted-foreground")}>{t("grafico.sola")}</div>
      )}

      <div className="flex flex-wrap gap-3">
        <SelectedWeek week={selected} opening={opening} onOpen={onOpen} />
        <ProfitByService rows={overview.services} weekCount={overview.count} />
      </div>

      <WeeksTable weeks={weeks} selectedId={selected.id} onSelect={onSelect} />
    </>
  );
}
