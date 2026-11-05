"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { useServiceName } from "@/hooks/use-service-name";
import { formatNumber } from "@/lib/format-number";
import { currentServiceOf } from "@/lib/remittance-operations/services";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { mixedGroupTotal, mixedShareDestination } from "./mixed-groups";

interface MixedSendBlockProps {
  /** Every operation of the group (history included): they hold the deposit's total between them. */
  members: RemittanceOperationRead[];
  /** The group's open operation cards. */
  children: ReactNode;
  /** Set when one verified deposit pays the whole send and every part is ready: the block shows that deposit and one
   *  "Completar envio" in place of each part's own "Completar". */
  completion?: { transId: string; onComplete: () => void };
}

/** Header over the cards of one mixed send (migration 253): the deposit they share and each member's service and share. */
export function MixedSendBlock({ members, children, completion }: MixedSendBlockProps) {
  const t = useTranslations("Inbox.operationsPanel.mixedSend");
  const serviceName = useServiceName();

  return (
    <section className="space-y-2 rounded-xl border border-dashed border-border p-2">
      <header className="px-1">
        <h4 className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">{t("title")}</h4>
        <p className="text-sm font-semibold tabular-nums text-foreground">
          {t("total", { amount: formatNumber(mixedGroupTotal(members)) })}
        </p>
        <ul className="text-xs tabular-nums text-muted-foreground">
          {members.map((member) => {
            const destination = mixedShareDestination(member);
            return (
              <li key={member.id}>
                {t("share", {
                  service: serviceName(currentServiceOf(member)),
                  amount: formatNumber(member.quotedSourceAmount ?? 0),
                })}
                {destination !== null ? ` → ${destination}` : null}
              </li>
            );
          })}
        </ul>
        {completion ? (
          <div className="mt-2 space-y-2">
            <p className="rounded-md border border-border bg-muted/40 px-2 py-1.5 text-xs tabular-nums text-foreground">
              {t("verifiedDeposit", { transId: completion.transId.slice(-4) })}
            </p>
            <Button type="button" size="lg" className="w-full" onClick={completion.onComplete}>
              {t("complete")}
            </Button>
          </div>
        ) : null}
      </header>
      {children}
    </section>
  );
}
