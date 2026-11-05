"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import { useServiceName } from "@/hooks/use-service-name";
import { formatNumber } from "@/lib/format-number";
import { currentServiceOf } from "@/lib/remittance-operations/services";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { StatusChip } from "./operation-icons";
import { mixedGroupTotal, mixedShareDestination } from "./mixed-groups";

interface MixedSendBlockProps {
  /** Every operation of the group (history included): they hold the deposit's total between them. */
  members: RemittanceOperationRead[];
  /** The group's open operation cards. */
  children: ReactNode;
  /** The group's status, shown once here so its cards do not repeat it. */
  statusChip?: { status: string; label: string };
  /** The one verified deposit that pays the whole send (its TransID); shown as a line under the shares. */
  depositTransId?: string;
  /** The group's actions ("Completar envio", "Cerrar manualmente"), placed after the cards like a card's own. */
  actions?: ReactNode;
  /** The open inline completion: it replaces the shares, cards and actions under the header. */
  section?: ReactNode;
}

/** Header over the cards of one mixed send (migration 253): the deposit they share and each member's service and share. */
export function MixedSendBlock({ members, children, statusChip, depositTransId, actions, section }: MixedSendBlockProps) {
  const t = useTranslations("Inbox.operationsPanel.mixedSend");
  const serviceName = useServiceName();

  return (
    <section className="space-y-2 rounded-xl border border-dashed border-border p-2">
      <header className="px-1">
        <div className="flex items-center justify-between gap-2">
          <h4 className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">{t("title")}</h4>
          {statusChip && <StatusChip status={statusChip.status} label={statusChip.label} />}
        </div>
        <p className="text-sm font-semibold tabular-nums text-foreground">
          {t("total", { amount: formatNumber(mixedGroupTotal(members)) })}
        </p>
        {!section && (
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
        )}
        {!section && depositTransId ? (
          <p className="mt-2 rounded-md border border-border bg-muted/40 px-2 py-1.5 text-xs tabular-nums text-foreground">
            {t("verifiedDeposit", { transId: depositTransId.slice(-4) })}
          </p>
        ) : null}
      </header>
      {section ?? (
        <>
          {children}
          {actions}
        </>
      )}
    </section>
  );
}
