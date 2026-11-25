"use client";

import { useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { useAuth } from "@/hooks/use-auth";
import { canManageResellers } from "@/lib/auth/roles";
import { fetchResellerDetail } from "@/lib/resellers/client";
import { formatGyd, formatResellerDate, formatSignedGyd } from "@/lib/resellers/format";
import type { ResellerDetail } from "@/lib/resellers/read-model";
import { Button } from "@/components/ui/button";
import { ResellerAdjustDialog } from "./reseller-adjust-dialog";
import { ResellerResetDialog } from "./reseller-reset-dialog";

/**
 * Inbox sidebar block for a reseller-tagged contact. The parent renders it only
 * when the contact carries the reseller tag, so a non-reseller costs no extra
 * request. Any member sees the current total; only admins see the write actions.
 */
export function ResellerSidebarBlock({ contactId }: { contactId: string }) {
  const t = useTranslations("Resellers.sidebar");
  const tRoot = useTranslations("Resellers");
  const locale = useLocale();
  const { accountRole } = useAuth();
  const canManage = accountRole ? canManageResellers(accountRole) : false;

  const [detail, setDetail] = useState<ResellerDetail | null>(null);
  const [error, setError] = useState(false);
  const [resetOpen, setResetOpen] = useState(false);
  const [adjustOpen, setAdjustOpen] = useState(false);
  // Bumped after a write so the effect refetches the block.
  const [version, setVersion] = useState(0);

  useEffect(() => {
    let cancelled = false;
    fetchResellerDetail(contactId)
      .then((next) => {
        if (cancelled) return;
        setDetail(next);
        setError(false);
      })
      .catch(() => {
        if (!cancelled) setError(true);
      });
    return () => {
      cancelled = true;
    };
  }, [contactId, version]);

  if (error) {
    return <p className="px-1 text-xs text-muted-foreground">{t("error")}</p>;
  }
  if (!detail) {
    return <p className="px-1 text-xs text-muted-foreground">{tRoot("loading")}</p>;
  }

  const current = detail.current;

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-2 px-1">
        <span className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
          {t("title")}
        </span>
      </div>
      <div className="rounded-lg bg-muted px-3 py-2">
        <p className="text-[10px] uppercase tracking-wider text-muted-foreground">
          {t("currentTotal")}
        </p>
        <p className="text-lg font-bold tabular-nums text-foreground">
          {formatGyd(current.totalGyd)}
        </p>
        <p className="text-[11px] text-muted-foreground">
          {current.periodStart
            ? tRoot("periodFrom", {
                date: formatResellerDate(current.periodStart, locale),
              })
            : tRoot("periodAllTime")}
        </p>
        <dl className="mt-1 grid grid-cols-2 gap-1 text-[11px]">
          <div>
            <dt className="text-muted-foreground">{t("deposited")}</dt>
            <dd className="font-medium tabular-nums text-foreground">
              {formatGyd(current.countedGyd)}
            </dd>
          </div>
          <div>
            <dt className="text-muted-foreground">{t("deposits")}</dt>
            <dd className="font-medium tabular-nums text-foreground">
              {formatGyd(current.depositsGyd)}
            </dd>
          </div>
          {current.historicalOperationsGyd !== 0 ? (
            <div>
              <dt className="text-muted-foreground">{t("historicalOperations")}</dt>
              <dd className="font-medium tabular-nums text-foreground">
                {formatGyd(current.historicalOperationsGyd)}
              </dd>
            </div>
          ) : null}
          <div>
            <dt className="text-muted-foreground">{t("adjustments")}</dt>
            <dd className="font-medium tabular-nums text-foreground">
              {formatSignedGyd(current.adjustmentsGyd)}
            </dd>
          </div>
        </dl>
        {detail.pendingClaims > 0 ? (
          <p className="mt-1 text-[11px] text-amber-600 dark:text-amber-400">
            {t("pendingClaims", { count: detail.pendingClaims })}
          </p>
        ) : null}
        {current.operationsMissingAmount > 0 ? (
          <p className="mt-1 text-[11px] text-amber-600 dark:text-amber-400">
            {t("missingAmount", { count: current.operationsMissingAmount })}
          </p>
        ) : null}
        <a
          href="/finanzas?tab=revendedores"
          className="mt-2 inline-block text-[11px] font-medium text-primary underline-offset-2 hover:underline"
        >
          {t("detail")}
        </a>
      </div>

      {canManage ? (
        <div className="flex gap-2 px-1">
          <Button size="sm" variant="outline" onClick={() => setAdjustOpen(true)}>
            {t("adjust")}
          </Button>
          <Button size="sm" variant="outline" onClick={() => setResetOpen(true)}>
            {t("reset")}
          </Button>
        </div>
      ) : null}

      <ResellerResetDialog
        open={resetOpen}
        mode="single"
        contactId={contactId}
        resellerName={detail.name}
        amountGyd={current.totalGyd}
        breakdown={{
          depositsGyd: current.depositsGyd,
          historicalOperationsGyd: current.historicalOperationsGyd,
          adjustmentsGyd: current.adjustmentsGyd,
        }}
        onClose={() => setResetOpen(false)}
        onDone={() => setVersion((value) => value + 1)}
      />
      <ResellerAdjustDialog
        open={adjustOpen}
        contactId={contactId}
        resellerName={detail.name}
        currentTotalGyd={current.totalGyd}
        onClose={() => setAdjustOpen(false)}
        onSaved={() => setVersion((value) => value + 1)}
      />
    </div>
  );
}
