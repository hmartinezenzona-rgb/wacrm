"use client";

import { useTranslations } from "next-intl";
import { Info } from "lucide-react";

/**
 * Shown on a closed operation (raw status `completed` or `cancelled`) that an
 * owner/admin may still correct (migration 383). It states that the edit is
 * audited and that nothing else is recalculated: the calculator lines and the
 * card inventories belong to the calculator, not to this edit.
 */
export function ClosedEditBanner() {
  const t = useTranslations("Inbox.operationsPanel");

  return (
    <div
      role="note"
      className="flex items-start gap-2 rounded-lg border border-border bg-muted/60 px-2.5 py-2 text-xs text-muted-foreground"
    >
      <Info className="mt-0.5 size-3.5 shrink-0" aria-hidden="true" />
      <p>
        <span className="font-medium text-foreground">{t("closedEdit.title")}. </span>
        {t("closedEdit.body")}
      </p>
    </div>
  );
}
