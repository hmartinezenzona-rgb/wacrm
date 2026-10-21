"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
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
}

/** Header over the cards of one mixed send (migration 253): the deposit they share and each member's service and share. */
export function MixedSendBlock({ members, children }: MixedSendBlockProps) {
  const t = useTranslations("Inbox.operationsPanel.mixedSend");
  const serviceName = useServiceName();

  return (
    <section className="space-y-2 rounded-lg border border-dashed border-border p-1.5">
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
      </header>
      {children}
    </section>
  );
}
