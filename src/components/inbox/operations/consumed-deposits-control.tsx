"use client";

import { useState, type FormEvent } from "react";
import { Unlink } from "lucide-react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldRow, UNDERLINE_SELECT_TRIGGER } from "./edit-form-fields";
import { moverDeposito } from "@/lib/remittance-operations/commands";
import type { MatchedDeposit } from "@/lib/remittance-operations/types";

interface Target {
  id: string;
  label: string;
}

interface ConsumedDepositsControlProps {
  operationId: string;
  /** The verified deposits of this operation. */
  deposits: MatchedDeposit[];
  /** The other open operations of the same conversation, the places a deposit can move to. */
  targets: Target[];
  /** The deposit was released or moved: the panel refreshes. */
  onMoved: () => void;
}

const RELEASE = "release";

/**
 * Release or move a verified deposit (migration 381): one row per deposit with a button; the choice is "leave it without an owner" (it goes
 * back to the ledger and can be linked elsewhere) or one of the other open operations of the conversation. The deposit moves whole and the
 * new states are muted: the person tells the customer. The server re-checks role, states and that the deposit is of this operation.
 */
export function ConsumedDepositsControl({ operationId, deposits, targets, onMoved }: ConsumedDepositsControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [openTransId, setOpenTransId] = useState<string | null>(null);
  const [choice, setChoice] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (deposits.length === 0) return null;

  function close() {
    setOpenTransId(null);
    setChoice("");
    setError(null);
  }

  async function handleSubmit(event: FormEvent, transId: string) {
    event.preventDefault();
    if (choice === "") return;
    setError(null);
    setPending(true);
    const result = await moverDeposito(operationId, transId, choice === RELEASE ? null : choice);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    close();
    onMoved();
  }

  return (
    <ul className="space-y-1">
      {deposits.map((deposit) => (
        <li key={deposit.transId} className="text-xs">
          <div className="flex items-center gap-1">
            <div className="min-w-0 flex-1">
              <span className="font-semibold tabular-nums">
                {deposit.amount === null ? "" : `${deposit.amount.toLocaleString("en-US")} ${deposit.currency ?? ""}`}
              </span>{" "}
              <span className="font-mono text-[11px] text-muted-foreground">{deposit.transId}</span>
            </div>
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t("depositMove.button")}
              title={t("depositMove.button")}
              onClick={() => {
                setError(null);
                setChoice("");
                setOpenTransId(openTransId === deposit.transId ? null : deposit.transId);
              }}
            >
              <Unlink aria-hidden="true" />
            </Button>
          </div>
          {openTransId === deposit.transId && (
            <form onSubmit={(event) => handleSubmit(event, deposit.transId)} onKeyDown={cancelOnEscape(close)} className={`${EDIT_AREA} mt-1`}>
              <p className="text-muted-foreground">{t("depositMove.warning")}</p>
              <FieldRow label={t("depositMove.choose")} htmlFor={`deposit-move-${deposit.transId}`}>
                <Select id={`deposit-move-${deposit.transId}`} value={choice} disabled={pending} onValueChange={(value) => setChoice(value ?? "")}>
                  <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
                    {/* Base UI paints the raw value unless it is given the label. */}
                    <SelectValue placeholder={t("depositMove.choose")}>
                      {(value) =>
                        value === RELEASE
                          ? t("depositMove.release")
                          : (targets.find((target) => target.id === value)?.label ?? t("depositMove.choose"))
                      }
                    </SelectValue>
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={RELEASE}>{t("depositMove.release")}</SelectItem>
                    {targets.map((target) => (
                      <SelectItem key={target.id} value={target.id}>
                        {target.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </FieldRow>
              <div className="flex items-center gap-2">
                {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
                <ConfirmCancelButtons
                  type="submit"
                  onCancel={close}
                  confirmLabel={t("depositMove.confirm")}
                  pending={pending}
                  confirmDisabled={choice === ""}
                />
              </div>
            </form>
          )}
        </li>
      ))}
    </ul>
  );
}
