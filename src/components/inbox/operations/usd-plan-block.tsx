"use client";

// ============================================================
// Clásica / Tropical inventory block of the delivery panel.
//   * before completion: "Sale de (estimado)" — one row per card and lot the USD will leave from, with the lot discount. When a
//     service lacks balance, one clear red message ("Faltan X USD en Tropical: compra saldo antes de completar") and the container
//     disables completing (the server refuses anyway, migration 356).
//   * after completion: "Salió de" — the lines that really left and the real USDT cost.
// `UsdPlanView` is presentational; `UsdPlanBlock` reads GET /api/remittance-operations/{id}/usd-plan, reports whether the plan is
// blocked, and renders nothing when the operation is not Clásica/Tropical, there is no inventory, or the request fails: completing
// a transfer never depends on it (a failed read never blocks).
// ============================================================

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { discountLabel, formatUsd } from "@/lib/usd-inventory/format";
import { isUsdPlanBlocked, visibleUsdPanel, type UsdPanelLine, type UsdPanelRead } from "@/lib/usd-inventory/panel";

const TITLE = "text-xs font-medium text-muted-foreground";
const ROW = "text-xs text-foreground";

function LineRows({ lines, testId }: { lines: UsdPanelLine[]; testId: string }) {
  const t = useTranslations("Inbox.operationsPanel.usdPlan");
  return (
    <>
      {lines.map((line, index) => {
        const discount = discountLabel(line.usdPerUsdt);
        const lot = discount === "1x1" ? t("lot1x1") : t("lotAt", { discount });
        const amount = formatUsd(line.amountUsd);
        return (
          <p key={`${line.lotId}-${index}`} className={ROW} data-testid={testId}>
            {line.last4 ? t("line", { card: line.cardName, last4: line.last4, amount, lot }) : t("lineNoLast4", { card: line.cardName, amount, lot })}
          </p>
        );
      })}
    </>
  );
}

export function UsdPlanView({ read }: { read: UsdPanelRead }) {
  const t = useTranslations("Inbox.operationsPanel.usdPlan");
  const visible = visibleUsdPanel(read);
  if (!visible) return null;

  if (visible.state === "plan") {
    const short = visible.services.filter((service) => service.blocked || service.missingUsd > 0);
    return (
      <div className="space-y-1 border-t border-border pt-2" data-testid="usd-plan">
        <p className={TITLE}>{t("planTitle")}</p>
        <LineRows lines={visible.services.flatMap((service) => service.lines)} testId="usd-plan-line" />
        {short.map((service) => (
          <p key={service.service} role="alert" className="text-xs font-medium text-red-600 dark:text-red-400">
            {t("blocked", { amount: formatUsd(service.missingUsd), service: t(`service${service.service}`) })}
          </p>
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-1 border-t border-border pt-2" data-testid="usd-used">
      <p className={TITLE}>{t("usedTitle")}</p>
      <LineRows lines={visible.lines} testId="usd-used-line" />
      <p className={ROW}>{t("cost", { usdt: formatUsd(visible.investedUsdt) })}</p>
      {visible.shortfallUsd > 0 ? (
        <p role="status" className="text-[11px] text-amber-500">
          {t("shortfall", { amount: formatUsd(visible.shortfallUsd) })}
        </p>
      ) : null}
    </div>
  );
}

const STATES = ["plan", "completed", "unavailable", "not_usd", "no_inventory", "no_amounts"];

/** The route already maps the RPC payload to camelCase; only the state is checked here. */
function isRead(value: unknown): value is UsdPanelRead {
  const state = (value as { state?: unknown } | null)?.state;
  return typeof state === "string" && STATES.includes(state);
}

export function UsdPlanBlock({
  operationId,
  onBlockedChange,
}: {
  operationId: string;
  /** Called with true while the plan says the balance is short; false otherwise (including when the read fails). */
  onBlockedChange?: (blocked: boolean) => void;
}) {
  // Keyed by operation so a read of another operation is never shown for this one.
  const [loaded, setLoaded] = useState<{ operationId: string; read: UsdPanelRead } | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const response = await fetch(`/api/remittance-operations/${operationId}/usd-plan`, { cache: "no-store" });
        if (!response.ok) return;
        const body = (await response.json()) as { usdPlan?: unknown };
        const read = body.usdPlan;
        if (!cancelled && isRead(read)) {
          setLoaded({ operationId, read });
          onBlockedChange?.(isUsdPlanBlocked(read));
        }
      } catch {
        // Quiet on purpose: the block is informative and completing the transfer must not depend on it.
      }
    })();
    return () => {
      cancelled = true;
    };
    // onBlockedChange is a state setter of the container; re-reading on its identity would loop.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [operationId]);

  return loaded && loaded.operationId === operationId ? <UsdPlanView read={loaded.read} /> : null;
}
