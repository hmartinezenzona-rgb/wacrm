"use client";

// ============================================================
// CUP inventory block of the delivery panel (phase 3).
//   * before completion: "Transfiere desde (estimado)" — which card each beneficiary's CUP will leave from (the real
//     deduction happens at completion), and a warning when part of it has no card with limit today. Only a warning:
//     completing is never blocked.
//   * after completion: "Salió de" — the cards and lot rates the CUP really left from.
// `CupPlanView` is presentational; `CupPlanBlock` reads GET /api/remittance-operations/{id}/cup-plan and renders nothing at
// all when the operation is not CUP, there is no inventory, or the request fails: completing a transfer never depends on it.
// ============================================================

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
  buildPlanLines,
  buildUsedLines,
  visibleCupPanel,
  type CupPanelRead,
} from "@/lib/cup-inventory/panel";
import { formatCup, formatRate } from "@/lib/cup-inventory/format";

const TITLE = "text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground";

export function CupPlanView({ read }: { read: CupPanelRead }) {
  const t = useTranslations("Inbox.operationsPanel.cupPlan");
  const visible = visibleCupPanel(read);
  if (!visible) return null;

  if (visible.state === "plan") {
    return (
      <div className="space-y-1" data-testid="cup-plan">
        <p className={TITLE}>{t("planTitle")}</p>
        <ul className="space-y-0.5 text-xs text-foreground">
          {buildPlanLines(visible).map((l) => (
            <li key={l.key}>
              {t("planLine", {
                beneficiary: l.beneficiary ?? t("beneficiaryN", { n: l.position }),
                amount: l.amountText,
                card: l.card ?? t("noCard"),
              })}
            </li>
          ))}
        </ul>
        {visible.missingCup > 0 && (
          <p role="status" className="rounded-md bg-amber-500/10 px-2 py-1.5 text-[11px] leading-relaxed text-amber-500">
            {t("missing", { amount: formatCup(visible.missingCup) })}
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-1" data-testid="cup-used">
      <p className={TITLE}>{t("usedTitle")}</p>
      <ul className="space-y-0.5 text-xs text-foreground">
        {buildUsedLines(visible).map((l) => (
          <li key={l.key}>{t("usedLine", { card: l.card, amount: l.amountText, rate: l.rateText })}</li>
        ))}
      </ul>
      {visible.cupRate !== null && (
        <p className="text-[11px] text-muted-foreground">{t("resultingRate", { rate: formatRate(visible.cupRate) })}</p>
      )}
    </div>
  );
}

function isRead(value: unknown): value is CupPanelRead {
  const state = (value as { state?: unknown } | null)?.state;
  return typeof state === "string";
}

export function CupPlanBlock({ operationId }: { operationId: string }) {
  // Keyed by operation so a read of another operation is never shown for this one.
  const [loaded, setLoaded] = useState<{ operationId: string; read: CupPanelRead } | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const response = await fetch(`/api/remittance-operations/${operationId}/cup-plan`, { cache: "no-store" });
        if (!response.ok) return;
        const body = (await response.json()) as { cupPlan?: unknown };
        if (!cancelled && isRead(body.cupPlan)) setLoaded({ operationId, read: body.cupPlan });
      } catch {
        // Quiet on purpose: the block is informative and completing the transfer must not depend on it.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [operationId]);

  return loaded && loaded.operationId === operationId ? <CupPlanView read={loaded.read} /> : null;
}
