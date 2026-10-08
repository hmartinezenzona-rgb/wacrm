"use client";

import { useTranslations } from "next-intl";
import { BarChart } from "@/components/tremor/bar-chart";
import { shortDayLabel } from "@/lib/financial-close/periods";
import type { FinancialClose } from "@/lib/financial-close/read-model";
import { ledgerServiceLabel } from "@/lib/calculator/entry-display";
import { ServiceDot } from "@/components/service/service-dot";
import { MoneyTotalFigure } from "@/components/money/money-total-figure";
import { moneyCellProps, moneyStripeClass, profitTone, totalTone, type TotalKind } from "@/lib/money-tone";
import { fmtGyd, marginPct } from "./financial-close-format";

/** Totals, the per-day chart and the per-service breakdown of one period. */
export function FinancialCloseSummary({ close }: { close: FinancialClose }) {
  const t = useTranslations("Resumen.cierre");
  const { totals } = close;
  const margin = marginPct(totals.facturadoGyd, totals.retornoGyd);

  const tiles: { label: string; kind?: TotalKind; value: number; note?: string | null }[] = [
    { label: t("totales.facturado"), kind: "in", value: totals.facturadoGyd },
    { label: t("totales.invertido"), kind: "out", value: totals.invertidoGyd },
    {
      label: t("totales.retorno"),
      kind: "result",
      value: totals.retornoGyd,
      note: margin === null ? null : t("totales.margen", { pct: margin }),
    },
    { label: t("totales.operaciones"), value: totals.operations },
  ];

  // Two series in the same unit (GYD) on one axis. Blue/pink validated
  // (dataviz validate_palette.js) in light and dark mode.
  const facturadoLabel = t("totales.facturado");
  const retornoLabel = t("totales.retorno");
  const chartData = close.byDay.map((d) => ({
    day: shortDayLabel(d.day),
    [facturadoLabel]: d.facturadoGyd,
    [retornoLabel]: d.retornoGyd,
  }));

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {tiles.map((tile) => (
          <div
            key={tile.label}
            className={`rounded-xl border border-border bg-card p-4 ${tile.kind ? moneyStripeClass[totalTone(tile.kind, tile.value)] : ""}`}
          >
            <p className="text-xs font-medium text-muted-foreground">{tile.label}</p>
            <p className="mt-2 text-xl font-bold tabular-nums text-foreground">
              {tile.kind ? (
                <MoneyTotalFigure kind={tile.kind} value={tile.value} format={fmtGyd} />
              ) : (
                tile.value.toLocaleString("en-US")
              )}
            </p>
            {tile.note && <p className="mt-1 text-xs text-muted-foreground">{tile.note}</p>}
          </div>
        ))}
      </div>

      {totals.operations === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-4 py-6 text-center text-sm text-muted-foreground">
          {t("sinDatos")}
        </p>
      ) : (
        <div className="grid gap-3 lg:grid-cols-5">
          {close.byDay.length > 1 && (
            <section className="rounded-xl border border-border bg-card p-4 lg:col-span-3">
              <h3 className="mb-2 text-sm font-semibold text-foreground">{t("porDia")}</h3>
              <BarChart
                data={chartData}
                index="day"
                categories={[facturadoLabel, retornoLabel]}
                colors={["blue", "pink"]}
                valueFormatter={(v) => fmtGyd(v)}
                yAxisWidth={84}
                className="h-[240px]"
              />
            </section>
          )}

          <section
            className={`rounded-xl border border-border bg-card p-4 ${close.byDay.length > 1 ? "lg:col-span-2" : "lg:col-span-5"}`}
          >
            <h3 className="mb-2 text-sm font-semibold text-foreground">{t("porServicio")}</h3>
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-muted-foreground">
                  <th className="py-1 font-medium">{t("cols.servicio")}</th>
                  <th className="py-1 text-right font-medium">{t("cols.operaciones")}</th>
                  <th className="py-1 text-right font-medium">{t("cols.facturado")}</th>
                  <th className="py-1 text-right font-medium">{t("cols.retorno")}</th>
                </tr>
              </thead>
              <tbody>
                {close.byService.map((s) => (
                  <tr
                    key={s.service}
                    data-testid="service-row"
                    data-service={s.service}
                    className="border-t border-border tabular-nums"
                  >
                    <td className="py-1.5 font-medium text-foreground">
                      <ServiceDot service={s.service} />
                      {ledgerServiceLabel(s.service)}
                    </td>
                    <td className="py-1.5 text-right">{s.operations}</td>
                    <td {...moneyCellProps("in", "py-1.5 text-right")}>{fmtGyd(s.facturadoGyd)}</td>
                    <td {...moneyCellProps(profitTone(s.retornoGyd), "py-1.5 text-right")}>
                      {fmtGyd(s.retornoGyd)}
                      {marginPct(s.facturadoGyd, s.retornoGyd) !== null && (
                        <span className="ml-1 text-xs text-muted-foreground">
                          ({marginPct(s.facturadoGyd, s.retornoGyd)}%)
                        </span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        </div>
      )}
    </div>
  );
}
