"use client";

// ============================================================
// CUP inventory block of the delivery panel (phase 3).
//   * before completion: "Transfiere desde · estimado" — grouped by card, which beneficiaries' CUP will leave from each (the real
//     deduction happens at completion), and a warning when part of it has no card with limit today. Only a warning:
//     completing is never blocked.
//   * after completion: "Salió de" — the cards and lot rates the CUP really left from.
// `CupPlanView` is presentational; `CupPlanBlock` reads GET /api/remittance-operations/{id}/cup-plan and renders nothing at
// all when the operation is not CUP, there is no inventory, or the request fails: completing a transfer never depends on it.
// ============================================================

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
  groupConsumptionsByCard,
  groupPlanByCard,
  visibleCupPanel,
  type CupPanelRead,
} from "@/lib/cup-inventory/panel";
import { formatRate } from "@/lib/cup-inventory/format";

const TITLE = "text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground";
const HEADER = "flex items-baseline justify-between gap-2 text-xs font-semibold text-foreground";
const ROW = "flex items-baseline justify-between gap-2 pl-3 text-[11px] text-muted-foreground";
const AMOUNT = "shrink-0 tabular-nums";

function CardHeader({ name, last4, total }: { name: string; last4: string | null; total: string }) {
  const t = useTranslations("Inbox.operationsPanel.cupPlan");
  return (
    <div className={HEADER}>
      <span className="min-w-0 truncate">
        {name}
        {last4 ? <span className="font-normal text-muted-foreground"> ·{last4}</span> : null}
      </span>
      <span className={`${AMOUNT} text-right`}>{t("cardTotal", { amount: total })}</span>
    </div>
  );
}

export function CupPlanView({ read }: { read: CupPanelRead }) {
  const t = useTranslations("Inbox.operationsPanel.cupPlan");
  const visible = visibleCupPanel(read);
  if (!visible) return null;

  if (visible.state === "plan") {
    const { cards, shortages } = groupPlanByCard(visible);
    return (
      <div className="space-y-1.5" data-testid="cup-plan">
        <p className={TITLE}>{t("planTitle")}</p>
        {cards.map((card) => (
          <div key={card.key} className="space-y-0.5" data-testid="cup-plan-card">
            <CardHeader name={card.name} last4={card.last4} total={card.totalText} />
            {card.rows.map((r) => (
              <div key={r.key} className={ROW}>
                <span className="min-w-0 truncate">
                  {t("beneficiaryRow", { beneficiary: r.beneficiary ?? t("beneficiaryN", { n: r.position }) })}
                </span>
                <span className={`${AMOUNT} text-right`}>{r.amountText}</span>
              </div>
            ))}
          </div>
        ))}
        {shortages.length > 0 && (
          <div role="status" className="space-y-0.5 rounded-md bg-amber-500/10 px-2 py-1.5 text-[11px] leading-relaxed text-amber-500">
            {shortages.map((s) => (
              <p key={s.key} className="font-medium">
                {t("missing", { amount: s.amountText, beneficiary: s.beneficiary ?? t("beneficiaryN", { n: s.position }) })}
              </p>
            ))}
            <p>{t("missingNote")}</p>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-1.5" data-testid="cup-used">
      <p className={TITLE}>{t("usedTitle")}</p>
      {groupConsumptionsByCard(visible).map((card) => (
        <div key={card.key} className="space-y-0.5" data-testid="cup-used-card">
          <CardHeader name={card.name} last4={card.last4} total={card.totalText} />
          {card.rows.map((r) => (
            <div key={r.key} className={ROW}>
              <span className="min-w-0 truncate">{t("lotRate", { rate: r.rateText })}</span>
              <span className={`${AMOUNT} text-right`}>{r.amountText}</span>
            </div>
          ))}
        </div>
      ))}
      {visible.cupRate !== null && (
        <p className="border-t border-border pt-1 text-[11px] text-muted-foreground">{t("resultingRate", { rate: formatRate(visible.cupRate) })}</p>
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
