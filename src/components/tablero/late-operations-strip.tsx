"use client";

import { setInboxOpenTarget } from "@/lib/inbox/open-target";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { formatCurrency } from "@/lib/currency";
import { useOperationServiceName } from "@/hooks/use-service-name";
import { ageParts, chatHref, lateOperations, type BoardOperation } from "@/lib/tablero/board";

interface LateOperationsStripProps {
  operations: ReadonlyArray<BoardOperation>;
  now: Date;
}

/** "Atrasadas": the stalest in-flight operations above the columns, oldest first, with a link to the chat. Computed from
 *  the board's own data; renders nothing when no operation is late. */
export function LateOperationsStrip({ operations, now }: LateOperationsStripProps) {
  const t = useTranslations("Tablero");
  const operationServiceName = useOperationServiceName();
  const late = lateOperations(operations, now);
  if (late.length === 0) return null;
  return (
    <section aria-labelledby="late-operations-title" className="border-border bg-card rounded-xl border p-3 shadow-[var(--elev-card)]">
      <h2 id="late-operations-title" className="text-status-danger text-sm font-semibold">{t("late.title")}</h2>
      <p className="text-muted-foreground mt-0.5 text-xs">{t("late.description")}</p>
      <ul className="divide-border mt-2 divide-y">
        {late.map((op) => {
          const name = op.contactName?.trim() || op.contactPhone || t("unknownContact");
          const age = ageParts(op.stateSince, now);
          return (
            <li key={op.operationId} className="flex items-center justify-between gap-3 py-2 text-sm">
              <span className="text-foreground min-w-0 flex-1 truncate font-medium">{name}</span>
              <span className="text-muted-foreground shrink-0 text-xs">
                {operationServiceName({ serviceType: op.serviceType, deliveryMethod: op.deliveryMethod })}
              </span>
              {op.quotedSourceAmount !== null ? (
                <span className="text-foreground shrink-0 font-bold tabular-nums">{formatCurrency(op.quotedSourceAmount, "GYD")}</span>
              ) : null}
              <span className="text-status-danger shrink-0 text-xs tabular-nums">{t(`age.${age.unit}`, { value: age.value })}</span>
              <Link
                href={chatHref(op.conversationId)}
                onClick={() => setInboxOpenTarget(op.conversationId)}
                className="text-primary shrink-0 text-xs font-medium hover:underline"
              >
                {t("late.openChat")}
              </Link>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
