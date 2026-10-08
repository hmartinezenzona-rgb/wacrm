"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { cn } from "@/lib/utils";
import { statusTone, type StatusTone } from "@/lib/status-tone";
import { useOperationServiceName, useServiceName } from "@/hooks/use-service-name";
import { formatCurrency } from "@/lib/currency";
import {
  SERVICE_FILTERS,
  ageParts,
  ageTone,
  chatHref,
  groupBoard,
  showMissingBeneficiaries,
  type AgeTone,
  type BoardColumnId,
  type BoardOperation,
  type ServiceFilter,
} from "@/lib/tablero/board";

// Tone of each column's header (owner, 2026-10-08): the shared status tones, not raw palette colours. "Listas para
// transferir" is attention like everywhere else; green is only for the completed column.
const COLUMN_TONE: Record<BoardColumnId, StatusTone> = {
  requested: "neutral",
  depositCheck: "attention",
  readyToTransfer: "attention",
  completed: "success",
  incident: "danger",
};

// Class names are written out in full for Tailwind. Soft tinted background of a column header, per tone.
const HEADER_SOFT_CLASS: Record<StatusTone, string> = {
  neutral: "bg-muted",
  info: "bg-status-info-soft",
  attention: "bg-status-attention-soft",
  success: "bg-status-success-soft",
  danger: "bg-status-danger-soft",
};

// The solid accent stripe of a column header and of a card, per tone.
const STRIPE_CLASS: Record<StatusTone, string> = {
  neutral: "bg-muted-foreground",
  info: "bg-status-info",
  attention: "bg-status-attention",
  success: "bg-status-success",
  danger: "bg-status-danger",
};

// Colour of the "time in status" text. Never the only cue: the text carries the figure and the tooltip stays.
const AGE_CLASS: Record<AgeTone, string> = {
  muted: "text-muted-foreground",
  attention: "text-status-attention",
  danger: "text-status-danger",
};

/** 3px accent stripe on the inner left edge of its (relative, clipped) parent; it adds no size. */
function Stripe({ tone }: { tone: StatusTone }) {
  return <span data-stripe="" aria-hidden="true" className={cn("absolute inset-y-0 left-0 w-[3px]", STRIPE_CLASS[tone])} />;
}

function BoardCard({ op, now }: { op: BoardOperation; now: Date }) {
  const t = useTranslations("Tablero");
  const operationServiceName = useOperationServiceName();
  const name = op.contactName?.trim() || op.contactPhone || t("unknownContact");
  // A remittance reads as its rail (CUP, Zelle...), the generic "Remesa" only when the rail is not known yet.
  const serviceLabel = operationServiceName({ serviceType: op.serviceType, deliveryMethod: op.deliveryMethod });
  const age = ageParts(op.stateSince, now);
  const ageText = t(`age.${age.unit}`, { value: age.value });
  return (
    <Link
      href={chatHref(op.conversationId)}
      aria-label={t("openChat", { name })}
      className="border-border bg-card hover:border-primary/50 focus-visible:ring-ring relative block overflow-hidden rounded-lg border p-3 shadow-[var(--elev-card)] transition-colors focus-visible:ring-2 focus-visible:outline-none"
    >
      <Stripe tone={statusTone(op.status)} />
      <div className="flex items-start justify-between gap-2">
        <span className="text-foreground min-w-0 truncate text-sm font-semibold">{name}</span>
        <span
          className={cn("shrink-0 text-xs", AGE_CLASS[ageTone(op.stateSince, now, op.status)])}
          title={t("inState", { age: ageText })}
        >
          {ageText}
        </span>
      </div>
      <div className="mt-2 flex items-center justify-between gap-2">
        <span className="text-muted-foreground text-xs font-medium">{serviceLabel}</span>
        {op.quotedSourceAmount !== null ? (
          <span className="text-foreground text-base font-bold tabular-nums">
            {formatCurrency(op.quotedSourceAmount, "GYD")}
          </span>
        ) : null}
      </div>
      {showMissingBeneficiaries(op) ? (
        <p className="text-status-attention mt-2 flex items-center gap-1.5 text-xs font-medium">
          <span data-dot="" aria-hidden="true" className="bg-status-attention size-1.5 shrink-0 rounded-full" />
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
  const serviceName = useServiceName();
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
            {value === "all" ? t("filters.all") : serviceName(value)}
          </button>
        ))}
      </div>
      {/* The columns scroll sideways inside this box, never the page. */}
      <div className="-mx-4 overflow-x-auto px-4 pb-2 sm:mx-0 sm:px-0">
        <div className="flex min-w-max gap-3">
          {columns.map((col) => (
            <section key={col.id} className="bg-lane border-border flex w-72 shrink-0 flex-col rounded-xl border p-2">
              <h2
                className={cn(
                  "text-foreground relative flex items-center gap-2 overflow-hidden rounded-lg py-1.5 pr-2 pl-3 text-sm font-semibold",
                  HEADER_SOFT_CLASS[COLUMN_TONE[col.id]],
                )}
              >
                <Stripe tone={COLUMN_TONE[col.id]} />
                <span className="flex-1 truncate">{t(`columns.${col.id}`)}</span>
                <span className="text-foreground text-xs font-medium tabular-nums">{col.count}</span>
              </h2>
              <div className="mt-2 flex flex-col gap-2">
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
