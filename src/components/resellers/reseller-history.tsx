"use client";

import { useLocale, useTranslations } from "next-intl";
import type { ResellerPeriod } from "@/lib/resellers/read-model";
import { formatGyd, formatResellerDate } from "@/lib/resellers/format";

export interface ResellerOpenPeriod {
  periodStart: string | null;
  totalGyd: number;
}

/**
 * The reseller's period history. The open period (no reset marker yet) comes
 * first and is labelled as open; closed periods follow newest first with the
 * actor, the optional reason and the confirmed snapshot when it differs from
 * the live total (late corrections can move the live figure after a reset).
 */
export function ResellerHistory({
  periods,
  current = null,
}: {
  periods: ResellerPeriod[];
  current?: ResellerOpenPeriod | null;
}) {
  const t = useTranslations("Resellers.history");
  const tRoot = useTranslations("Resellers");
  const locale = useLocale();
  const day = (iso: string | null) =>
    iso === null ? null : formatResellerDate(iso, locale);
  const closed = [...periods].sort((a, b) => Date.parse(b.end) - Date.parse(a.end));
  const currentStart = current ? day(current.periodStart) : null;

  if (!current && closed.length === 0) {
    return <p className="text-sm text-muted-foreground">{t("empty")}</p>;
  }

  return (
    <section className="flex flex-col gap-2">
      <h3 className="text-sm font-semibold text-foreground">{t("title")}</h3>
      <ol className="flex flex-col gap-2">
        {current ? (
          <li className="rounded-lg border border-border bg-muted/40 p-3">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="text-xs font-semibold uppercase tracking-wider text-primary">
                {t("open")}
              </span>
              <span className="font-semibold tabular-nums text-foreground">
                {t("total", { amount: formatGyd(current.totalGyd) })}
              </span>
            </div>
            <p className="mt-1 text-xs text-muted-foreground">
              {currentStart
                ? t("from", { date: currentStart })
                : tRoot("periodAllTime")}
            </p>
          </li>
        ) : null}

        {closed.map((period) => {
          const start = day(period.start);
          const end = day(period.end);
          return (
            <li key={period.resetId} className="rounded-lg border border-border p-3">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="text-xs text-muted-foreground">
                  {start ? t("from", { date: start }) : tRoot("periodAllTime")}
                  {end ? ` · ${t("to", { date: end })}` : null}
                </span>
                <span className="font-semibold tabular-nums text-foreground">
                  {t("total", { amount: formatGyd(period.totalGyd) })}
                </span>
              </div>
              {period.depositsGyd !== 0 ? (
                <p className="mt-1 text-xs text-muted-foreground">
                  {t("deposits", { amount: formatGyd(period.depositsGyd) })}
                </p>
              ) : null}
              {period.closedDepositsGyd !== period.depositsGyd ? (
                <p className="mt-1 text-xs text-muted-foreground">
                  {t("closedDeposits", { amount: formatGyd(period.closedDepositsGyd) })}
                </p>
              ) : null}
              {period.closedTotalGyd !== period.totalGyd ? (
                <p className="mt-1 text-xs text-muted-foreground">
                  {t("closedSnapshot", { amount: formatGyd(period.closedTotalGyd) })}
                </p>
              ) : null}
              <p className="mt-1 text-xs text-muted-foreground">
                {period.resetByName
                  ? t("by", { name: period.resetByName })
                  : t("unknownActor")}
                {period.reason ? ` · ${t("reason", { reason: period.reason })}` : null}
              </p>
            </li>
          );
        })}
      </ol>
    </section>
  );
}
