"use client";

import { useLocale, useTranslations } from "next-intl";
import type { ResellerDetail } from "@/lib/resellers/read-model";
import { formatGyd, formatResellerDate, formatSignedGyd } from "@/lib/resellers/format";
import { ResellerHistory } from "./reseller-history";

/**
 * The reseller detail: current-period breakdown (operations, adjustments and
 * the missing-amount note), the adjustment history and the closed periods.
 * Adjustments are shown as their own line, never folded into the operations.
 */
export function ResellerDetailView({ detail }: { detail: ResellerDetail }) {
  const t = useTranslations("Resellers.detail");
  const tRoot = useTranslations("Resellers");
  const tHistory = useTranslations("Resellers.history");
  const locale = useLocale();
  const current = detail.current;
  const adjustments = [...current.adjustments].sort(
    (a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt),
  );

  return (
    <div className="flex flex-col gap-4">
      {detail.isReseller ? null : (
        <p role="status" className="rounded-lg border border-border bg-muted/40 p-3 text-sm text-muted-foreground">
          {t("notReseller")}
        </p>
      )}

      <section className="flex flex-col gap-2 rounded-xl border border-border bg-card p-3">
        <h3 className="text-sm font-semibold text-foreground">{t("current")}</h3>
        <p className="text-xs text-muted-foreground">
          {current.periodStart
            ? tRoot("periodFrom", { date: formatResellerDate(current.periodStart, locale) })
            : tRoot("periodAllTime")}
        </p>
        <dl className="grid grid-cols-2 gap-2 text-sm">
          <div>
            <dt className="text-xs text-muted-foreground">{tRoot("deposited")}</dt>
            <dd className="font-semibold tabular-nums text-foreground">{formatGyd(current.countedGyd)}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">{tRoot("deposits")}</dt>
            <dd className="font-semibold tabular-nums text-foreground">{formatGyd(current.depositsGyd)}</dd>
            <dd className="text-[11px] text-muted-foreground">{current.depositsCount}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">{tRoot("adjustments")}</dt>
            <dd className="font-semibold tabular-nums text-foreground">{formatSignedGyd(current.adjustmentsGyd)}</dd>
            <dd className="text-[11px] text-muted-foreground">{current.adjustmentsCount}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">{t("total")}</dt>
            <dd className="font-semibold tabular-nums text-foreground">{formatGyd(current.totalGyd)}</dd>
          </div>
        </dl>
        {current.historicalOperationsGyd !== 0 ? (
          <p className="text-xs text-muted-foreground">
            {tRoot("historicalOperations")}:{" "}
            <span className="font-medium tabular-nums text-foreground">
              {formatGyd(current.historicalOperationsGyd)}
            </span>
          </p>
        ) : null}
        {detail.pendingClaims > 0 ? (
          <div
            role="status"
            className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-2.5 py-1.5 text-xs text-amber-700 dark:text-amber-400"
          >
            <p className="font-medium">{tRoot("pendingClaims", { count: detail.pendingClaims })}</p>
            <p className="text-muted-foreground">{tRoot("pendingClaimsHint")}</p>
          </div>
        ) : null}
        {current.operationsMissingAmount > 0 ? (
          <p className="text-xs text-amber-600 dark:text-amber-400">
            {t("missingAmount", { count: current.operationsMissingAmount })}
          </p>
        ) : null}
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="text-sm font-semibold text-foreground">{t("adjustmentHistory")}</h3>
        {adjustments.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("noAdjustments")}</p>
        ) : (
          <ul className="flex flex-col gap-1.5">
            {adjustments.map((adjustment) => (
              <li key={adjustment.id} className="rounded-lg border border-border px-3 py-2">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="font-semibold tabular-nums text-foreground">
                    {formatSignedGyd(adjustment.amountGyd)}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {formatResellerDate(adjustment.createdAt, locale)}
                  </span>
                </div>
                <p className="text-xs text-muted-foreground">
                  {adjustment.actorName ?? tHistory("unknownActor")}
                  {adjustment.reason ? ` · ${tHistory("reason", { reason: adjustment.reason })}` : null}
                </p>
              </li>
            ))}
          </ul>
        )}
      </section>

      <ResellerHistory
        periods={detail.periods}
        current={{ periodStart: current.periodStart, totalGyd: current.totalGyd }}
      />
    </div>
  );
}
