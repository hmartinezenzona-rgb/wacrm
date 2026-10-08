"use client";

import { useTranslations } from "next-intl";
import { ledgerServiceLabel } from "@/lib/calculator/entry-display";
import { buildProfitRing } from "@/lib/financial-close/profit-ring";
import type { FinancialClose } from "@/lib/financial-close/read-model";
import { formatNumber } from "@/lib/format-number";
import { fmtGyd } from "./financial-close-format";

// The theme defines five chart tokens; services beyond the fifth reuse them at
// reduced opacity (as the dashboard ring does) and the legend carries the names.
const CHART_TOKENS = 5;
const sliceColor = (index: number) => `var(--chart-${(index % CHART_TOKENS) + 1})`;
const sliceOpacity = (index: number) => (index < CHART_TOKENS ? 1 : 0.55);

const pct = (share: number) => `${formatNumber(share * 100, { maximumFractionDigits: 1 })}%`;

/** Profit (retorno) by service of the loaded period: a ring of the positive profits plus a legend with every service. */
export function FinancialCloseProfitRing({ byService }: { byService: FinancialClose["byService"] }) {
  const t = useTranslations("Resumen.cierre");
  const ring = buildProfitRing(byService);
  const title = t("gananciaServicio.title");

  return (
    <section className="rounded-xl border border-border bg-card p-4">
      <h3 className="mb-2 text-sm font-semibold text-foreground">{title}</h3>
      {ring.rows.length === 0 ? (
        <p className="py-4 text-center text-sm text-muted-foreground">{t("sinDatos")}</p>
      ) : (
        <div className="flex flex-col items-center gap-4 sm:flex-row sm:gap-8">
          {ring.hasRing && <Donut ring={ring} title={title} />}
          <ul className="w-full min-w-0 flex-1 space-y-2">
            {ring.rows.map((row, i) => (
              <li
                key={row.service}
                data-testid="ring-row"
                data-service={row.service}
                className="flex items-center gap-3 text-xs"
              >
                <span
                  className="h-2.5 w-2.5 flex-shrink-0 rounded-full"
                  style={row.slice ? { background: sliceColor(i), opacity: sliceOpacity(i) } : { background: "var(--muted)" }}
                  aria-hidden
                />
                <span className="flex-1 truncate text-muted-foreground">{ledgerServiceLabel(row.service)}</span>
                <span className="whitespace-nowrap text-muted-foreground tabular-nums">{fmtGyd(row.profit)}</span>
                <span className="w-14 text-right text-muted-foreground tabular-nums">
                  {row.share === null ? "—" : pct(row.share)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}

// Same 200×200 arc renderer as the dashboard's service-volume ring.
function Donut({ ring, title }: { ring: ReturnType<typeof buildProfitRing>; title: string }) {
  const t = useTranslations("Resumen.cierre");
  const size = 200;
  const r = 80;
  const ringWidth = 18;
  const cx = size / 2;
  const cy = size / 2;
  const total = fmtGyd(ring.totalProfit);

  // Slices are the positive rows only, in the legend's order; the index into
  // `rows` keeps each swatch and slice on the same colour.
  const drawn = ring.rows.flatMap((row, i) => (row.slice ? [{ row, i }] : []));
  const offsets: number[] = [0];
  for (let k = 0; k < drawn.length; k++) offsets.push(offsets[k] + (drawn[k].row.share ?? 0));

  return (
    <svg
      viewBox={`0 0 ${size} ${size}`}
      className="h-48 w-48 flex-shrink-0"
      role="img"
      aria-label={t("gananciaServicio.ariaLabel", { total })}
    >
      <title>{title}</title>
      <circle cx={cx} cy={cy} r={r} fill="none" stroke="var(--muted)" strokeWidth={ringWidth} />
      {drawn.map(({ row, i }, k) => {
        const start = offsets[k] * Math.PI * 2 - Math.PI / 2;
        let end = offsets[k + 1] * Math.PI * 2 - Math.PI / 2;
        // A full sweep makes both arc endpoints coincide and SVG draws nothing; pull the end back a hair.
        if (end - start >= Math.PI * 2 - 1e-6) end -= 1e-3;
        return (
          <path
            key={row.service}
            data-testid="ring-slice"
            d={arcPath(cx, cy, r, start, end)}
            fill="none"
            stroke={sliceColor(i)}
            strokeWidth={ringWidth}
            strokeLinecap="butt"
            strokeOpacity={sliceOpacity(i)}
          />
        );
      })}
      <text x={cx} y={cy - 6} textAnchor="middle" className="fill-muted-foreground text-[11px]">
        {t("gananciaServicio.total")}
      </text>
      <text x={cx} y={cy + 14} textAnchor="middle" className="fill-foreground text-[13px] font-semibold tabular-nums">
        {total}
      </text>
    </svg>
  );
}

function arcPath(cx: number, cy: number, r: number, startRad: number, endRad: number): string {
  const x1 = cx + r * Math.cos(startRad);
  const y1 = cy + r * Math.sin(startRad);
  const x2 = cx + r * Math.cos(endRad);
  const y2 = cy + r * Math.sin(endRad);
  const largeArc = endRad - startRad > Math.PI ? 1 : 0;
  return `M ${x1} ${y1} A ${r} ${r} 0 ${largeArc} 1 ${x2} ${y2}`;
}
