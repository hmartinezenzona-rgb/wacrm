"use client";

import { AlertTriangle } from "lucide-react";
import { useTranslations } from "next-intl";

interface ResolverStateBannerProps {
  /** `resolverCandidateCount` from the read model — always >= 2 when this
   *  banner is shown (spec: chat-remesa-operations-panel, "Ambiguous
   *  state surfaces explicitly"). */
  candidateCount: number;
}

/**
 * Presentational. The panel's only signal for the `ambigua` resolver
 * state — it never picks a winner operation; every open remesa still
 * renders in the list below it (see `OperationsPanelContainer`).
 * A compact badge beside the panel title (owner, 2026-10-03: the full-width
 * block took room); the full explanation is its tooltip and accessible name.
 * It disappears on its own once one or no remesa is open.
 */
export function ResolverStateBanner({ candidateCount }: ResolverStateBannerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const explanation = t("ambiguousState", { count: candidateCount });
  return (
    <span
      role="status"
      title={explanation}
      aria-label={explanation}
      className="inline-flex items-center gap-1 rounded-full bg-amber-500/15 px-2 py-0.5 text-[11px] font-medium normal-case tracking-normal text-amber-700 dark:text-amber-300"
    >
      <AlertTriangle className="size-3" aria-hidden="true" />
      {t("ambiguousBadge", { count: candidateCount })}
    </span>
  );
}
