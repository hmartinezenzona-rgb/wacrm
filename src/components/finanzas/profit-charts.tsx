"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import {
  Bar,
  BarChart,
  CartesianGrid,
  LabelList,
  Line,
  LineChart,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { fmtGyd } from "@/components/resumen/financial-close-format";
import { useServiceName } from "@/hooks/use-service-name";
import { formatNumber } from "@/lib/format-number";
import type { FinancialClose } from "@/lib/financial-close/read-model";
import {
  profitByDaySeries,
  profitByServiceSeries,
  showDayChart,
  showServiceChart,
  type DayProfitPoint,
  type ServiceProfitPoint,
} from "@/lib/financial-close/profit-series";
import type { CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { showWeekChart, weeklyProfitSeries, type WeekProfitPoint } from "./week-profit-series";

// The three profit charts of Finanzas > Cierres. One series each, so no legend: the title names it. Marks wear the
// --chart-profit token (light/dark come from the design tokens); text, grid and axes use text and border tokens.
const MARK = "var(--chart-profit)";
const TEXT = "var(--muted-foreground)";
const GRID = "var(--border)";
const SURFACE = "var(--card)";
const AXIS_TICK = { fill: TEXT, fontSize: 11 };
const COMPACT = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const compact = (value: number) => COMPACT.format(value);
/** The table's number without the unit, for labels that sit beside a bar: the title states GYD. */
const plain = (value: number) => formatNumber(value, { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function ChartFigure({ title, label, height, className = "", children }: { title: string; label: string; height: number; className?: string; children: ReactNode }) {
  return (
    <figure aria-label={label} className={`m-0 ${className}`}>
      <figcaption className="mb-2 text-sm font-semibold text-foreground">{title}</figcaption>
      <div style={{ height }} className="w-full min-w-0">
        {children}
      </div>
    </figure>
  );
}

interface TipProps<T> {
  active?: boolean;
  payload?: readonly { payload?: T }[];
}

function TipCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="rounded-lg border border-border bg-card px-3 py-2 text-xs shadow-md">
      <p className="mb-1 font-medium text-muted-foreground">{title}</p>
      <div className="space-y-0.5">{children}</div>
    </div>
  );
}

/** Value first and strong, the name secondary: the reader already has the series and wants the number. */
function TipRow({ name, value }: { name: string; value: string }) {
  return (
    <p className="flex items-baseline justify-between gap-4 tabular-nums">
      <span className="text-muted-foreground">{name}</span>
      <span className="font-semibold text-foreground">{value}</span>
    </p>
  );
}

export function DayTooltip({ active, payload }: TipProps<DayProfitPoint>) {
  const t = useTranslations("Finanzas.graficos");
  const point = payload?.[0]?.payload;
  if (!active || !point) return null;
  return (
    <TipCard title={point.label}>
      <TipRow name={t("ganancia")} value={fmtGyd(point.retorno)} />
      <p className="text-muted-foreground">{t("operaciones", { count: point.operations })}</p>
    </TipCard>
  );
}

export function ServiceTooltip({ active, payload }: TipProps<ServiceProfitPoint>) {
  const t = useTranslations("Finanzas.graficos");
  const serviceName = useServiceName();
  const point = payload?.[0]?.payload;
  if (!active || !point) return null;
  return (
    <TipCard title={serviceName(point.service)}>
      <TipRow name={t("facturado")} value={fmtGyd(point.facturado)} />
      <TipRow name={t("invertido")} value={fmtGyd(point.invertido)} />
      <TipRow name={t("retorno")} value={fmtGyd(point.retorno)} />
      {point.margin !== null && <p className="text-muted-foreground">{t("margen", { pct: point.margin })}</p>}
    </TipCard>
  );
}

export function WeekTooltip({ active, payload }: TipProps<WeekProfitPoint>) {
  const t = useTranslations("Finanzas.graficos");
  const point = payload?.[0]?.payload;
  if (!active || !point) return null;
  return (
    <TipCard title={point.cutDate}>
      {point.periodo && <p className="text-muted-foreground">{t("periodo", { periodo: point.periodo })}</p>}
      <TipRow name={t("facturado")} value={fmtGyd(point.facturado)} />
      <TipRow name={t("retorno")} value={fmtGyd(point.retorno)} />
    </TipCard>
  );
}

const CURSOR = { fill: "var(--muted)", opacity: 0.5 };

/** Vertical bars, one per day, from a zero baseline; a losing day goes below it in the same colour. */
export function ProfitByDayChart({ byDay }: { byDay: FinancialClose["byDay"] }) {
  const t = useTranslations("Finanzas.graficos.gananciaDia");
  const series = profitByDaySeries(byDay);
  if (!showDayChart(series)) return null;
  return (
    <ChartFigure title={t("title")} label={t("aria")} height={220}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={series} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
          <CartesianGrid vertical={false} stroke={GRID} strokeWidth={1} />
          <XAxis dataKey="label" tick={AXIS_TICK} tickLine={false} axisLine={false} interval="preserveStartEnd" minTickGap={12} />
          <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} tickFormatter={compact} width={44} />
          <ReferenceLine y={0} stroke={GRID} strokeWidth={1} />
          <Tooltip cursor={CURSOR} content={(props) => <DayTooltip {...props} />} />
          <Bar dataKey="retorno" fill={MARK} maxBarSize={24} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        </BarChart>
      </ResponsiveContainer>
    </ChartFigure>
  );
}

const ROW_HEIGHT = 34;

/** Horizontal bars sorted by profit, highest first; every bar has the same colour and carries its value. */
export function ProfitByServiceChart({ byService, className }: { byService: FinancialClose["byService"]; className?: string }) {
  const t = useTranslations("Finanzas.graficos.gananciaServicio");
  const serviceName = useServiceName();
  const series = profitByServiceSeries(byService);
  if (!showServiceChart(series)) return null;
  return (
    <ChartFigure title={t("title")} label={t("aria")} height={series.length * ROW_HEIGHT + 24} className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={series} layout="vertical" margin={{ top: 4, right: 76, bottom: 4, left: 0 }}>
          <CartesianGrid horizontal={false} stroke={GRID} strokeWidth={1} />
          <XAxis type="number" hide />
          <YAxis
            type="category"
            dataKey="service"
            width={92}
            tick={AXIS_TICK}
            tickLine={false}
            axisLine={false}
            tickFormatter={(service: string) => serviceName(service)}
          />
          <ReferenceLine x={0} stroke={GRID} strokeWidth={1} />
          <Tooltip cursor={CURSOR} content={(props) => <ServiceTooltip {...props} />} />
          <Bar dataKey="retorno" fill={MARK} maxBarSize={20} radius={[0, 4, 4, 0]} isAnimationActive={false}>
            <LabelList dataKey="retorno" position="right" formatter={(v) => plain(Number(v))} fill="var(--foreground)" fontSize={11} />
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </ChartFigure>
  );
}

/** Profit of the latest archived weeks, oldest to newest: one line, one axis, a marker per week. */
export function WeeklyProfitChart({ weeks, className }: { weeks: CalculatorWeekSummary[]; className?: string }) {
  const t = useTranslations("Finanzas.graficos.gananciaSemana");
  const series = weeklyProfitSeries(weeks);
  if (!showWeekChart(series)) return null;
  return (
    <ChartFigure title={t("title")} label={t("aria")} height={220} className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={series} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
          <CartesianGrid vertical={false} stroke={GRID} strokeWidth={1} />
          <XAxis dataKey="label" tick={AXIS_TICK} tickLine={false} axisLine={false} interval="preserveStartEnd" minTickGap={12} />
          <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} tickFormatter={compact} width={44} />
          <ReferenceLine y={0} stroke={GRID} strokeWidth={1} />
          <Tooltip cursor={{ stroke: GRID, strokeWidth: 1 }} content={(props) => <WeekTooltip {...props} />} />
          <Line
            type="linear"
            dataKey="retorno"
            stroke={MARK}
            strokeWidth={2}
            strokeLinecap="round"
            strokeLinejoin="round"
            dot={{ r: 4, fill: MARK, stroke: SURFACE, strokeWidth: 2 }}
            activeDot={{ r: 6, fill: MARK, stroke: SURFACE, strokeWidth: 2 }}
            isAnimationActive={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </ChartFigure>
  );
}
