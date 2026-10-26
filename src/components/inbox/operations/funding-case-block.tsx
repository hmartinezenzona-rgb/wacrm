"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { AlertTriangle, Wallet } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useServiceName } from "@/hooks/use-service-name";
import { formatNumber } from "@/lib/format-number";
import type {
  FundingCasePanelRead,
  FundingCaseRead,
  FundingCaseStatus,
} from "@/lib/funding-case/types";

const STATUS_CLASS: Record<FundingCaseStatus, string> = {
  open: "bg-muted text-muted-foreground",
  allocating: "bg-primary/10 text-primary",
  incident: "bg-destructive/10 text-destructive",
  closed: "bg-muted text-muted-foreground",
};

interface FundingCaseBlockProps {
  conversationId: string;
}

/**
 * The conversation's funding case: verified / assigned / available GYD,
 * the linked deposits, the allocations and — when the engine found a
 * conflict — the incident note with the resolve action. Renders nothing
 * when the conversation has no case yet, so it can sit in the sidebar
 * without adding an empty section.
 */
export function FundingCaseBlock({ conversationId }: FundingCaseBlockProps) {
  const t = useTranslations("Inbox.fundingCase");
  const serviceName = useServiceName();
  const [data, setData] = useState<FundingCaseRead | null>(null);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [resolving, setResolving] = useState(false);

  const load = useCallback(
    async (signal?: AbortSignal) => {
      setLoading(true);
      setFailed(false);
      try {
        const response = await fetch(
          `/api/funding-case?conversationId=${conversationId}`,
          { cache: "no-store", signal },
        );
        if (!response.ok) {
          setFailed(true);
          return;
        }
        const payload = (await response.json()) as FundingCasePanelRead;
        setData(payload.case ?? null);
      } catch (cause) {
        if ((cause as { name?: string } | null)?.name === "AbortError") return;
        setFailed(true);
      } finally {
        setLoading(false);
      }
    },
    [conversationId],
  );

  useEffect(() => {
    const controller = new AbortController();
    void load(controller.signal);
    return () => controller.abort();
  }, [load]);

  const resolve = useCallback(async () => {
    if (!data) return;
    setResolving(true);
    try {
      const response = await fetch(`/api/funding-case/${data.id}/resolve`, {
        method: "POST",
      });
      if (!response.ok) {
        toast.error(t("resolveError"));
        return;
      }
      toast.success(t("resolved"));
      await load();
    } catch {
      toast.error(t("resolveError"));
    } finally {
      setResolving(false);
    }
  }, [data, load, t]);

  if (loading) {
    return <p className="px-1 text-xs text-muted-foreground">{t("loading")}</p>;
  }
  if (failed) {
    return <p className="px-1 text-xs text-muted-foreground">{t("loadError")}</p>;
  }
  if (!data) return null;

  const statusLabel =
    data.status === "open"
      ? t("status.open")
      : data.status === "allocating"
        ? t("status.allocating")
        : data.status === "incident"
          ? t("status.incident")
          : t("status.closed");

  return (
    <section className="space-y-2 border-t border-border px-1 pt-3" aria-label={t("title")}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-1.5 text-xs font-medium uppercase tracking-wider text-muted-foreground">
          <Wallet className="h-3 w-3" />
          {t("title")}
        </div>
        <span
          className={`rounded-full px-2 py-0.5 text-[10px] font-medium ${STATUS_CLASS[data.status]}`}
        >
          {statusLabel}
        </span>
      </div>

      <dl className="grid grid-cols-3 gap-1 rounded-lg border border-border bg-muted/40 p-2 text-center">
        <div>
          <dt className="text-[10px] uppercase tracking-wide text-muted-foreground">
            {t("verified")}
          </dt>
          <dd className="text-xs font-medium">{formatNumber(data.depositado)}</dd>
        </div>
        <div>
          <dt className="text-[10px] uppercase tracking-wide text-muted-foreground">
            {t("assigned")}
          </dt>
          <dd className="text-xs font-medium">{formatNumber(data.asignado)}</dd>
        </div>
        <div>
          <dt className="text-[10px] uppercase tracking-wide text-muted-foreground">
            {t("available")}
          </dt>
          <dd className="text-xs font-medium">{formatNumber(data.disponible)}</dd>
        </div>
      </dl>

      <div>
        <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
          {t("deposits")}
        </p>
        {data.deposits.length === 0 ? (
          <p className="mt-1 text-[11px] text-muted-foreground">{t("noDeposits")}</p>
        ) : (
          <ul className="mt-1 max-h-24 space-y-1 overflow-y-auto">
            {data.deposits.map((deposit) => (
              <li
                key={deposit.trans_id}
                className="flex items-center justify-between gap-2 text-[11px]"
              >
                <span
                  className={`truncate font-mono text-[10px] ${
                    deposit.anulado_en ? "text-muted-foreground line-through" : ""
                  }`}
                  title={deposit.trans_id}
                >
                  {deposit.trans_id}
                </span>
                <span className="shrink-0 font-medium">
                  {formatNumber(Number(deposit.monto))} GYD
                  {deposit.anulado_en ? ` · ${t("voided")}` : ""}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div>
        <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
          {t("allocations")}
        </p>
        {data.allocations.length === 0 ? (
          <p className="mt-1 text-[11px] text-muted-foreground">{t("noAllocations")}</p>
        ) : (
          <ul className="mt-1 max-h-24 space-y-1 overflow-y-auto">
            {data.allocations.map((allocation) => (
              <li
                key={allocation.id}
                className="flex items-center justify-between gap-2 text-[11px]"
              >
                <span className="truncate" title={allocation.operation_id}>
                  {allocation.service
                    ? serviceName(allocation.service)
                    : `${t("operation")} ${allocation.operation_id.slice(0, 8)}`}
                </span>
                <span className="shrink-0 font-medium">
                  {formatNumber(Number(allocation.amount_gyd))} GYD
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {data.status === "incident" && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-2">
          <div className="flex items-start gap-1.5 text-xs text-destructive">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <div>
              <p className="font-medium">{t("conflictTitle")}</p>
              {data.note && (
                <p className="mt-0.5 text-[11px] text-destructive/90">{data.note}</p>
              )}
            </div>
          </div>
          <Button
            type="button"
            size="sm"
            variant="outline"
            className="mt-2 h-7 text-xs"
            onClick={resolve}
            disabled={resolving}
          >
            {resolving ? t("resolving") : t("resolve")}
          </Button>
        </div>
      )}

      {data.status === "closed" && (
        <p className="text-[11px] text-muted-foreground">{t("closedHint")}</p>
      )}
    </section>
  );
}
