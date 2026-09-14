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
 */
export function ResolverStateBanner({ candidateCount }: ResolverStateBannerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  return (
    <div
      role="status"
      className="flex items-start gap-2 rounded-lg bg-amber-500/10 p-2.5 text-xs font-medium text-amber-700 dark:text-amber-300"
    >
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
      <span>{t("ambiguousState", { count: candidateCount })}</span>
    </div>
  );
}
