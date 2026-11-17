"use client";

import { useState } from "react";
import { Link2 } from "lucide-react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA } from "./edit-form-fields";
import { NotifyToggle } from "./notify-toggle";
import { fetchFreeDeposits } from "@/lib/remittance-operations/commands";
import type { FreeDeposit } from "@/lib/remittance-operations/types";

interface FreeDepositsPickerProps {
  operationId: string;
  /** A verification is in flight: the link buttons lock. */
  busy: boolean;
  /** Links the deposit (the panel runs the existing verify with its TransID and amount). `notify` is the bell. */
  onLink: (deposit: FreeDeposit, notify: boolean) => void;
}

type Loaded = { status: "loading" } | { status: "error" } | { status: "loaded"; deposits: FreeDeposit[] };

function formatReceived(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

/**
 * "Link a deposit without an owner" (migration 380): the MMG ledger deposits nobody owns, newest first. Picking one hands it to the panel,
 * which links it to this operation with the verify it already has, so the crossing, the status change and the customer notice are the
 * ones of every verification. The bell starts on, as in the verify section.
 */
export function FreeDepositsPicker({ operationId, busy, onLink }: FreeDepositsPickerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [open, setOpen] = useState(false);
  const [state, setState] = useState<Loaded>({ status: "loading" });
  const [notify, setNotify] = useState(true);

  async function openList() {
    setOpen(true);
    setState({ status: "loading" });
    const result = await fetchFreeDeposits(operationId);
    setState(result.ok ? { status: "loaded", deposits: result.data } : { status: "error" });
  }

  function close() {
    setOpen(false);
  }

  if (!open) {
    return (
      <Button type="button" variant="ghost" size="sm" aria-label={t("freeDeposits.button")} onClick={openList}>
        <Link2 aria-hidden="true" />
        {t("freeDeposits.button")}
      </Button>
    );
  }

  return (
    <div className={EDIT_AREA} onKeyDown={cancelOnEscape(close)}>
      {state.status === "loading" && <p className="text-xs text-muted-foreground">{t("freeDeposits.loading")}</p>}
      {state.status === "error" && <p className="text-xs text-destructive">{t("freeDeposits.loadError")}</p>}
      {state.status === "loaded" && state.deposits.length === 0 && (
        <p className="text-xs text-muted-foreground">{t("freeDeposits.empty")}</p>
      )}
      {state.status === "loaded" && state.deposits.length > 0 && (
        <ul className="max-h-56 space-y-1 overflow-y-auto">
          {state.deposits.map((deposit) => (
            <li key={deposit.transId} className="flex items-center gap-1 text-xs">
              <div className="min-w-0 flex-1">
                <p className="font-semibold tabular-nums">
                  {deposit.amount.toLocaleString("en-US")} {deposit.currency}
                </p>
                <p className="truncate text-muted-foreground">
                  {formatReceived(deposit.receivedAt)}
                  {deposit.holder ? ` · ${deposit.holder}` : ""}
                </p>
                <p className="truncate font-mono text-[11px] text-muted-foreground">{deposit.transId}</p>
              </div>
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                aria-label={t("freeDeposits.link")}
                title={t("freeDeposits.link")}
                disabled={busy}
                onClick={() => {
                  onLink(deposit, notify);
                  close();
                }}
              >
                <Link2 aria-hidden="true" />
              </Button>
            </li>
          ))}
        </ul>
      )}
      <ConfirmCancelButtons onCancel={close} pending={false} confirmDisabled>
        <NotifyToggle notify={notify} onChange={setNotify} disabled={busy} />
      </ConfirmCancelButtons>
    </div>
  );
}
