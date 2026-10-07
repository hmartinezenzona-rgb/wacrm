"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { AlertTriangle } from "lucide-react";
import { cn } from "@/lib/utils";
import { formatCurrency } from "@/lib/currency";
import {
  SERVICE_FILTERS,
  ageParts,
  chatHref,
  groupBoard,
  showMissingBeneficiaries,
  type BoardColumnId,
  type BoardOperation,
  type ServiceFilter,
} from "@/lib/tablero/board";
import { PICKER_ICON } from "@/components/inbox/operations/operation-closing-control";
import { MethodIcon } from "@/components/inbox/operations/operation-icons";

const COLUMN_TONE: Record<BoardColumnId, string> = {
  requested: "bg-muted-foreground",
  depositCheck: "bg-amber-500",
  readyToTransfer: "bg-emerald-500",
  incident: "bg-red-500",
  completed: "bg-primary",
};

const KNOWN_SERVICES = ["remesa", "recarga", "combo", "visa", "saldo"] as const;

function ServiceBadge({ op, label }: { op: BoardOperation; label: string }) {
  // A remittance shows its delivery method icon (as the chat panel does); the
  // other services have their own icon, the same ones the panel's picker uses.
  const picker = PICKER_ICON[op.serviceType];
  return (
    <span className="text-muted-foreground inline-flex items-center gap-1.5 text-xs font-medium">
      {picker ? (
        <picker.Icon className={cn("size-4 shrink-0", picker.className)} aria-hidden="true" />
      ) : (
        <MethodIcon method={op.deliveryMethod} label={label} />
      )}
      {label}
    </span>
  );
}

function BoardCard({ op, now }: { op: BoardOperation; now: Date }) {
  const t = useTranslations("Tablero");
  const name = op.contactName?.trim() || op.contactPhone || t("unknownContact");
  const serviceLabel = (KNOWN_SERVICES as ReadonlyArray<string>).includes(op.serviceType)
    ? t(`services.${op.serviceType}`)
    : op.serviceType;
  const age = ageParts(op.stateSince, now);
  const ageText = t(`age.${age.unit}`, { value: age.value });
  return (
    <Link
      href={chatHref(op.conversationId)}
      aria-label={t("openChat", { name })}
      className="border-border bg-card hover:border-primary/50 focus-visible:ring-ring block rounded-lg border p-3 shadow-xs transition-colors focus-visible:ring-2 focus-visible:outline-none"
    >
      <div className="flex items-start justify-between gap-2">
        <span className="text-foreground min-w-0 truncate text-sm font-semibold">{name}</span>
        <span className="text-muted-foreground shrink-0 text-xs" title={t("inState", { age: ageText })}>
          {ageText}
        </span>
      </div>
      <div className="mt-2 flex items-center justify-between gap-2">
        <ServiceBadge op={op} label={serviceLabel} />
        {op.quotedSourceAmount !== null ? (
          <span className="text-foreground text-sm font-medium tabular-nums">
            {formatCurrency(op.quotedSourceAmount, "GYD")}
          </span>
        ) : null}
      </div>
      {showMissingBeneficiaries(op) ? (
        <p className="mt-2 flex items-center gap-1.5 text-xs font-medium text-amber-700 dark:text-amber-300">
          <AlertTriangle className="size-3.5 shrink-0" aria-hidden="true" />
          {t("missingBeneficiaries")}
        </p>
      ) : null}
    </Link>
  );
}

interface OperationsBoardProps {
  operations: ReadonlyArray<BoardOperation>;
  filter: ServiceFilter;
  onFilterChange: (filter: ServiceFilter) => void;
  now: Date;
}

/** Read-only board: columns by status, one card per operation, a service
 *  filter. The only interactions are the filter and the link to the chat. */
export function OperationsBoard({ operations, filter, onFilterChange, now }: OperationsBoardProps) {
  const t = useTranslations("Tablero");
  const columns = groupBoard(operations, filter);
  return (
    <div className="space-y-4">
      <div role="group" aria-label={t("filterLabel")} className="flex flex-wrap gap-2">
        {SERVICE_FILTERS.map((value) => (
          <button
            key={value}
            type="button"
            aria-pressed={filter === value}
            onClick={() => onFilterChange(value)}
            className={cn(
              "rounded-full border px-3 py-1 text-xs font-medium transition-colors",
              filter === value
                ? "border-primary bg-primary/10 text-primary"
                : "border-border text-muted-foreground hover:bg-muted hover:text-foreground",
            )}
          >
            {t(`filters.${value}`)}
          </button>
        ))}
      </div>
      {/* The columns scroll sideways inside this box, never the page. */}
      <div className="-mx-4 overflow-x-auto px-4 pb-2 sm:mx-0 sm:px-0">
        <div className="flex min-w-max gap-3">
          {columns.map((col) => (
            <section key={col.id} className="bg-muted/40 flex w-72 shrink-0 flex-col rounded-xl p-2">
              <h2 className="text-foreground flex items-center gap-2 px-1 py-1.5 text-sm font-semibold">
                <span className={cn("size-2 shrink-0 rounded-full", COLUMN_TONE[col.id])} aria-hidden="true" />
                <span className="flex-1 truncate">{t(`columns.${col.id}`)}</span>
                <span className="text-muted-foreground text-xs font-medium tabular-nums">{col.count}</span>
              </h2>
              <div className="flex flex-col gap-2">
                {col.items.length === 0 ? (
                  <p className="text-muted-foreground px-1 py-4 text-center text-xs">{t("emptyColumn")}</p>
                ) : (
                  col.items.map((op) => <BoardCard key={op.operationId} op={op} now={now} />)
                )}
              </div>
            </section>
          ))}
        </div>
      </div>
    </div>
  );
}
