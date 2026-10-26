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
  FundingCaseResolveRead,
  FundingCaseStatus,
} from "@/lib/funding-case/types";

const STATUS_CLASS: Record<FundingCaseStatus, string> = {
  open: "bg-muted text-muted-foreground",
  allocating: "bg-primary/10 text-primary",
  incident: "bg-destructive/10 text-destructive",
  closed: "bg-muted text-muted-foreground",
};

/** A fresh key per operator action; a retry of the same action keeps its key. */
function newIdempotencyKey(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

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
  const [assignOpen, setAssignOpen] = useState(false);
  const [assignOperationId, setAssignOperationId] = useState("");
  const [assignAmount, setAssignAmount] = useState("");
  const [assignKey, setAssignKey] = useState("");
  const [assigning, setAssigning] = useState(false);
  const [releaseId, setReleaseId] = useState<string | null>(null);
  const [releasing, setReleasing] = useState(false);

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
      const payload = (await response.json()) as FundingCaseResolveRead;
      if (payload.status === "incident") {
        // The engine re-evaluated and the data still shows the conflict.
        toast.error(payload.conflict ?? t("resolveError"));
      } else {
        toast.success(t("resolved"));
      }
      await load();
    } catch {
      toast.error(t("resolveError"));
    } finally {
      setResolving(false);
    }
  }, [data, load, t]);

  const openAssign = useCallback(() => {
    const first = data?.operations?.[0];
    setAssignOperationId(first?.id ?? "");
    setAssignAmount(
      first
        ? String(Math.max(Number(first.quoted_source_amount) - Number(first.allocated), 0))
        : "",
    );
    setAssignKey(newIdempotencyKey());
    setAssignOpen(true);
  }, [data]);

  const assign = useCallback(async () => {
    if (!data || !assignOperationId || !assignKey) return;
    const amount = Number(assignAmount);
    if (!Number.isFinite(amount) || amount <= 0) {
      toast.error(t("assignInvalid"));
      return;
    }
    setAssigning(true);
    try {
      const response = await fetch(`/api/funding-case/${data.id}/assign`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          operationId: assignOperationId,
          amountGyd: amount,
          idempotencyKey: assignKey,
        }),
      });
      if (!response.ok) {
        const payload = (await response.json().catch(() => ({}))) as { error?: string };
        toast.error(`${t("assignError")}: ${payload.error ?? response.status}`);
        return;
      }
      const payload = (await response.json()) as FundingCasePanelRead;
      if (payload.case) setData(payload.case);
      setAssignOpen(false);
      toast.success(t("assignSaved"));
    } catch {
      toast.error(t("assignError"));
    } finally {
      setAssigning(false);
    }
  }, [assignAmount, assignKey, assignOperationId, data, t]);

  const release = useCallback(
    async (allocationId: string) => {
      if (!data) return;
      setReleasing(true);
      try {
        const response = await fetch(`/api/funding-case/${data.id}/release`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ allocationId, idempotencyKey: newIdempotencyKey() }),
        });
        if (!response.ok) {
          const payload = (await response.json().catch(() => ({}))) as { error?: string };
          toast.error(`${t("releaseError")}: ${payload.error ?? response.status}`);
          return;
        }
        const payload = (await response.json()) as FundingCasePanelRead;
        if (payload.case) setData(payload.case);
        setReleaseId(null);
        toast.success(t("releaseSaved"));
      } catch {
        toast.error(t("releaseError"));
      } finally {
        setReleasing(false);
      }
    },
    [data, t],
  );

  if (loading) {
    return <p className="px-1 text-xs text-muted-foreground">{t("loading")}</p>;
  }
  if (failed) {
    return <p className="px-1 text-xs text-muted-foreground">{t("loadError")}</p>;
  }
  if (!data) return null;
  const operations = data.operations ?? [];
  const releaseAllocation = releaseId
    ? data.allocations.find((allocation) => allocation.id === releaseId) ?? null
    : null;

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
        <div className="flex items-center justify-between">
          <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
            {t("allocations")}
          </p>
          {operations.length > 0 && !assignOpen && (
            <button
              type="button"
              className="text-[10px] font-medium text-primary hover:underline"
              onClick={openAssign}
            >
              {t("assign")}
            </button>
          )}
        </div>
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
                <span className="flex shrink-0 items-center gap-1.5">
                  <span className="font-medium">
                    {formatNumber(Number(allocation.amount_gyd))} GYD
                  </span>
                  {allocation.status === "committed" && (
                    <button
                      type="button"
                      className="text-[10px] text-destructive hover:underline"
                      onClick={() => setReleaseId(allocation.id)}
                    >
                      {t("release")}
                    </button>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}

        {releaseAllocation && (
          <div className="mt-2 rounded-lg border border-border bg-muted/30 p-2">
            <p className="text-[11px]">
              {t("releaseQuestion", {
                amount: formatNumber(Number(releaseAllocation.amount_gyd)),
              })}
            </p>
            <div className="mt-2 flex gap-2">
              <Button
                type="button"
                size="sm"
                variant="outline"
                className="h-7 text-xs"
                onClick={() => release(releaseAllocation.id)}
                disabled={releasing}
              >
                {releasing ? t("releasing") : t("releaseConfirm")}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                className="h-7 text-xs"
                onClick={() => setReleaseId(null)}
                disabled={releasing}
              >
                {t("releaseCancel")}
              </Button>
            </div>
          </div>
        )}

        {assignOpen && (
          <div className="mt-2 space-y-2 rounded-lg border border-border bg-muted/30 p-2">
            <p className="text-[11px] font-medium">{t("assignTitle")}</p>
            <label className="block text-[10px] uppercase tracking-wide text-muted-foreground">
              {t("assignOperation")}
              <select
                className="mt-1 w-full rounded border border-border bg-background px-2 py-1 text-[11px] normal-case tracking-normal text-foreground"
                value={assignOperationId}
                onChange={(event) => setAssignOperationId(event.target.value)}
              >
                {operations.map((operation) => (
                  <option key={operation.id} value={operation.id}>
                    {operation.service
                      ? serviceName(operation.service)
                      : `${t("operation")} ${operation.id.slice(0, 8)}`}
                    {" · "}
                    {formatNumber(Number(operation.quoted_source_amount))} GYD ·{" "}
                    {t("allocated", { amount: formatNumber(Number(operation.allocated)) })}
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-[10px] uppercase tracking-wide text-muted-foreground">
              {t("assignAmount")}
              <input
                type="number"
                min="1"
                step="1"
                value={assignAmount}
                onChange={(event) => setAssignAmount(event.target.value)}
                className="mt-1 w-full rounded border border-border bg-background px-2 py-1 text-[11px] normal-case tracking-normal text-foreground"
              />
            </label>
            <div className="flex gap-2">
              <Button
                type="button"
                size="sm"
                className="h-7 text-xs"
                onClick={assign}
                disabled={assigning}
              >
                {assigning ? t("assigning") : t("assignConfirm")}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                className="h-7 text-xs"
                onClick={() => setAssignOpen(false)}
                disabled={assigning}
              >
                {t("assignCancel")}
              </Button>
            </div>
          </div>
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
