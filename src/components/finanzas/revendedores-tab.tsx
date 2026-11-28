"use client";

import { useCallback, useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { Users } from "lucide-react";
import { useAuth } from "@/hooks/use-auth";
import { canManageResellers } from "@/lib/auth/roles";
import {
  fetchResellerDetail,
  fetchResellerSummary,
} from "@/lib/resellers/client";
import { formatGyd, formatResellerDate } from "@/lib/resellers/format";
import type {
  ResellerDetail,
  ResellerSummary,
  ResellerSummaryRead,
} from "@/lib/resellers/read-model";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { ResellerAdjustDialog } from "@/components/resellers/reseller-adjust-dialog";
import { ResellerDetailView } from "@/components/resellers/reseller-detail";
import { ResellerResetDialog } from "@/components/resellers/reseller-reset-dialog";

const CARD = "min-w-0 rounded-xl border border-border bg-card p-4 text-card-foreground";

/**
 * Finanzas "Revendedores" tab: the reseller list with the grand total, the
 * admin-only reset / reset-all / adjust actions and a detail drawer with the
 * current period, the adjustments and the closed-period history.
 */
export function RevendedoresTab({ active = true }: { active?: boolean }) {
  const t = useTranslations("Resellers");
  const locale = useLocale();
  const { accountRole } = useAuth();
  const canManage = accountRole ? canManageResellers(accountRole) : false;

  const [data, setData] = useState<ResellerSummaryRead | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [selected, setSelected] = useState<ResellerSummary | null>(null);
  const [detail, setDetail] = useState<ResellerDetail | null>(null);
  const [detailError, setDetailError] = useState(false);
  const [resetTarget, setResetTarget] = useState<ResellerSummary | null>(null);
  const [resetAllOpen, setResetAllOpen] = useState(false);
  const [adjustTarget, setAdjustTarget] = useState<ResellerSummary | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setData(await fetchResellerSummary());
      setError(false);
    } catch {
      setError(true);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (active) void load();
  }, [active, load]);

  useEffect(() => {
    if (!selected) return;
    let cancelled = false;
    setDetail(null);
    setDetailError(false);
    fetchResellerDetail(selected.contactId)
      .then((next) => {
        if (!cancelled) setDetail(next);
      })
      .catch(() => {
        if (!cancelled) setDetailError(true);
      });
    return () => {
      cancelled = true;
    };
  }, [selected]);

  const afterWrite = useCallback(() => {
    void load();
    if (!selected) return;
    void fetchResellerDetail(selected.contactId)
      .then(setDetail)
      .catch(() => setDetailError(true));
  }, [load, selected]);

  return (
    <div className="flex flex-col gap-4" data-testid="revendedores-tab">
      {loading && !data ? (
        <p className="text-sm text-muted-foreground">{t("loading")}</p>
      ) : error ? (
        <div className={CARD}>
          <p className="text-sm text-foreground">{t("error")}</p>
          <Button type="button" variant="outline" className="mt-3" onClick={() => void load()}>
            {t("retry")}
          </Button>
        </div>
      ) : data ? (
        <>
          <section className={CARD} aria-label={t("grandTotal")}>
            <div className="flex flex-wrap items-end justify-between gap-3">
              <div>
                <h2 className="text-sm font-semibold text-muted-foreground">{t("grandTotal")}</h2>
                <p className="text-2xl font-bold tracking-tight tabular-nums text-foreground">
                  {formatGyd(data.grand.totalGyd)}
                </p>
              </div>
              {canManage ? (
                <Button type="button" variant="outline" onClick={() => setResetAllOpen(true)}>
                  {t("actions.resetAll")}
                </Button>
              ) : null}
            </div>
            <dl className="mt-3 grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
              <div>
                <dt className="text-xs text-muted-foreground">{t("deposited")}</dt>
                <dd className="font-medium tabular-nums text-foreground">{formatGyd(data.grand.countedGyd)}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">{t("deposits")}</dt>
                <dd className="font-medium tabular-nums text-foreground">{formatGyd(data.grand.depositsGyd)}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">{t("grandAdjustments")}</dt>
                <dd className="font-medium tabular-nums text-foreground">{formatGyd(data.grand.adjustmentsGyd)}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">{t("title")}</dt>
                <dd className="font-medium text-foreground">{t("resellerCount", { count: data.grand.resellers })}</dd>
              </div>
            </dl>
            {data.grand.historicalOperationsGyd !== 0 ? (
              <p className="mt-2 text-xs text-muted-foreground">
                {t("historicalOperations")}:{" "}
                <span className="font-medium tabular-nums text-foreground">
                  {formatGyd(data.grand.historicalOperationsGyd)}
                </span>
              </p>
            ) : null}
          </section>

          {data.resellers.length === 0 ? (
            <EmptyState title={t("emptyTitle")} description={t("emptyHint")} icon={Users} />
          ) : (
            <section className="overflow-hidden rounded-xl border border-border">
              <div className="grid grid-cols-[1.4fr_1fr_1fr_1fr_auto] gap-2 border-b border-border bg-muted/50 px-3 py-2 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                <span>{t("columns.reseller")}</span>
                <span>{t("columns.period")}</span>
                <span className="text-right">{t("columns.deposited")}</span>
                <span className="text-right">{t("columns.adjustments")}</span>
                <span className="text-right">{t("columns.total")}</span>
              </div>
              <ul>
                {data.resellers.map((row) => (
                  <li
                    key={row.contactId}
                    data-testid="reseller-row"
                    className="grid grid-cols-[1.4fr_1fr_1fr_1fr_auto] items-center gap-2 border-b border-border/60 px-3 py-2.5 text-sm last:border-0"
                  >
                    <div className="min-w-0">
                      <p className="truncate font-medium text-foreground">{row.name ?? row.phone}</p>
                      <p className="truncate font-mono text-[11px] text-muted-foreground">{row.phone}</p>
                    </div>
                    <span className="text-xs text-muted-foreground">
                      {row.periodStart
                        ? t("periodFrom", { date: formatResellerDate(row.periodStart, locale) })
                        : t("periodAllTime")}
                    </span>
                    <span className="flex flex-col items-end text-right">
                      <span className="tabular-nums text-foreground">{formatGyd(row.countedGyd)}</span>
                      <span className="text-[10px] text-muted-foreground">
                        {t("deposits")}: {formatGyd(row.depositsGyd)}
                      </span>
                      {row.historicalOperationsGyd !== 0 ? (
                        <span className="text-[10px] text-muted-foreground">
                          {t("historicalOperations")}: {formatGyd(row.historicalOperationsGyd)}
                        </span>
                      ) : null}
                    </span>
                    <span className="text-right tabular-nums text-foreground">{formatGyd(row.adjustmentsGyd)}</span>
                    <span className="flex items-center justify-end gap-1">
                      <span className="mr-1 font-semibold tabular-nums text-foreground">{formatGyd(row.totalGyd)}</span>
                      <Button type="button" size="sm" variant="ghost" onClick={() => setSelected(row)}>
                        {t("actions.detail")}
                      </Button>
                      {canManage ? (
                        <>
                          <Button type="button" size="sm" variant="outline" onClick={() => setAdjustTarget(row)}>
                            {t("actions.adjust")}
                          </Button>
                          <Button type="button" size="sm" variant="outline" onClick={() => setResetTarget(row)}>
                            {t("actions.reset")}
                          </Button>
                        </>
                      ) : null}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      ) : null}

      <Sheet
        open={selected !== null}
        onOpenChange={(next) => {
          if (!next) {
            setSelected(null);
            setDetail(null);
          }
        }}
      >
        <SheetContent side="right" className="w-full sm:max-w-lg">
          <SheetHeader>
            <SheetTitle>{t("detail.title")}</SheetTitle>
            <SheetDescription>{selected?.name ?? selected?.phone ?? ""}</SheetDescription>
          </SheetHeader>
          <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">
            {detailError ? (
              <p className="text-sm text-muted-foreground">{t("detail.error")}</p>
            ) : detail ? (
              <ResellerDetailView detail={detail} />
            ) : (
              <p className="text-sm text-muted-foreground">{t("detail.loading")}</p>
            )}
          </div>
        </SheetContent>
      </Sheet>

      <ResellerResetDialog
        open={resetTarget !== null}
        mode="single"
        contactId={resetTarget?.contactId}
        resellerName={resetTarget?.name ?? resetTarget?.phone ?? null}
        amountGyd={resetTarget?.totalGyd ?? 0}
        breakdown={
          resetTarget
            ? {
                depositsGyd: resetTarget.depositsGyd,
                historicalOperationsGyd: resetTarget.historicalOperationsGyd,
                adjustmentsGyd: resetTarget.adjustmentsGyd,
              }
            : null
        }
        onClose={() => setResetTarget(null)}
        onDone={afterWrite}
      />
      <ResellerResetDialog
        open={resetAllOpen}
        mode="all"
        amountGyd={data?.grand.totalGyd ?? 0}
        breakdown={
          data
            ? {
                depositsGyd: data.grand.depositsGyd,
                historicalOperationsGyd: data.grand.historicalOperationsGyd,
                adjustmentsGyd: data.grand.adjustmentsGyd,
              }
            : null
        }
        resellerIds={data?.resellers.map((row) => row.contactId) ?? []}
        onClose={() => setResetAllOpen(false)}
        onDone={afterWrite}
      />
      <ResellerAdjustDialog
        open={adjustTarget !== null}
        contactId={adjustTarget?.contactId ?? ""}
        resellerName={adjustTarget?.name ?? adjustTarget?.phone ?? null}
        currentTotalGyd={adjustTarget?.totalGyd ?? 0}
        onClose={() => setAdjustTarget(null)}
        onSaved={() => afterWrite()}
      />
    </div>
  );
}
