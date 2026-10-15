"use client";

// ============================================================
// CUP inventory block of the delivery panel (phase 3).
//   * before completion: "Transferir desde" — one row per card with the CUP that will leave from it (the real deduction happens
//     at completion) and, when part of it has no card with limit today, one plain amber line. Only a warning: completing is never blocked.
//   * after completion: "Salió de" — one row per card with the CUP that really left from it.
// `CupPlanView` is presentational; `CupPlanBlock` reads GET /api/remittance-operations/{id}/cup-plan and renders nothing at
// all when the operation is not CUP, there is no inventory, or the request fails: completing a transfer never depends on it.
// ============================================================

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
  groupConsumptionsByCard,
  groupPlanByCard,
  visibleCupPanel,
  type CupCardTotal,
  type CupPanelRead,
} from "@/lib/cup-inventory/panel";

const TITLE = "text-xs font-medium text-muted-foreground";
const ROW = "flex items-baseline justify-between gap-2 text-xs text-foreground";

function CardRows({ cards, testId }: { cards: CupCardTotal[]; testId: string }) {
  const t = useTranslations("Inbox.operationsPanel.cupPlan");
  return (
    <>
      {cards.map((card) => (
        <div key={card.key} className={ROW} data-testid={testId}>
          <span className="min-w-0 truncate">
            {card.name}
            {card.last4 ? <span className="text-muted-foreground"> ·{card.last4}</span> : null}
          </span>
          <span className="shrink-0 text-right tabular-nums">{t("cardTotal", { amount: card.totalText })}</span>
        </div>
      ))}
    </>
  );
}

export function CupPlanView({ read }: { read: CupPanelRead }) {
  const t = useTranslations("Inbox.operationsPanel.cupPlan");
  const visible = visibleCupPanel(read);
  if (!visible) return null;

  if (visible.state === "plan") {
    const { cards, missingText } = groupPlanByCard(visible);
    return (
      <div className="space-y-1" data-testid="cup-plan">
        <p className={TITLE}>{t("planTitle")}</p>
        <CardRows cards={cards} testId="cup-plan-card" />
        {missingText !== null && (
          <p role="status" className="flex items-center gap-1.5 text-[11px] text-amber-500">
            <span aria-hidden="true" data-testid="cup-plan-dot" className="size-1.5 shrink-0 rounded-full bg-current" />
            {t("missing", { amount: missingText })}
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-1" data-testid="cup-used">
      <p className={TITLE}>{t("usedTitle")}</p>
      <CardRows cards={groupConsumptionsByCard(visible)} testId="cup-used-card" />
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
