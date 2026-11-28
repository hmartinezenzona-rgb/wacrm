"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useServiceName } from "@/hooks/use-service-name";
import { formatNumber } from "@/lib/format-number";
import { repartirEnvio } from "@/lib/remittance-operations/commands";
import { OPERATION_SERVICES, currentServiceOf } from "@/lib/remittance-operations/services";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import { mixedGroupTotal } from "./mixed-groups";

interface SplitDepositFormProps {
  /** The operation the split is requested through (any member of the group works). */
  operationId: string;
  /** The group's operations (history included), or the operation alone when it is not grouped. */
  members: RemittanceOperationRead[];
  onDone: () => void;
  onCancel: () => void;
}

interface PartRow {
  key: number;
  service: string;
  amount: string;
}

/** A typed GYD amount as a number. A dot that groups thousands ("20.000") is dropped and a comma is the decimal;
 *  anything else is read as typed, so an unreadable text is NaN and keeps the form locked. */
export function parseAmount(text: string): number {
  const compact = text.replace(/[\s ]/g, "");
  const grouped = /^\d{1,3}(\.\d{3})+(,\d+)?$/.test(compact) ? compact.replace(/\./g, "") : compact;
  return Number(grouped.replace(",", "."));
}

/** Money compared in cents, so a typed 0.1 + 0.2 still equals 0.3. */
const cents = (value: number) => Math.round(value * 100);

/**
 * Inline editor that splits one deposit across several services (`repartirEnvio`, migration 253). One row per part
 * (service + GYD), prefilled with the group's members or with the operation alone; the parts must add up exactly to
 * the group's current total, which the "assigned X of TOTAL" line tracks live. The check stays locked until there are
 * at least two parts, each with its own service and an amount above zero, adding up to the total. The server's
 * refusal is shown in the form. Confirmed with the check, cancelled with the X (as the correction form).
 */
export function SplitDepositForm({ operationId, members, onDone, onCancel }: SplitDepositFormProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const serviceName = useServiceName();
  const total = mixedGroupTotal(members);

  const [rows, setRows] = useState<PartRow[]>(() =>
    members.map((member, index) => ({
      key: index,
      service: currentServiceOf(member) ?? "",
      amount: member.quotedSourceAmount === null ? "" : String(member.quotedSourceAmount),
    })),
  );
  const [nextKey, setNextKey] = useState(members.length);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const amounts = rows.map((row) => parseAmount(row.amount));
  const assigned = amounts.reduce((sum, amount) => sum + (Number.isFinite(amount) ? amount : 0), 0);
  const services = rows.map((row) => row.service);
  const valid =
    rows.length >= 2 &&
    services.every((service) => service !== "") &&
    new Set(services).size === services.length &&
    amounts.every((amount) => Number.isFinite(amount) && amount > 0) &&
    cents(assigned) === cents(total);

  function updateRow(key: number, change: Partial<PartRow>) {
    setRows((current) => current.map((row) => (row.key === key ? { ...row, ...change } : row)));
  }

  function addRow() {
    setRows((current) => [...current, { key: nextKey, service: "", amount: "" }]);
    setNextKey((current) => current + 1);
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!valid || pending) return;
    setError(null);
    setPending(true);
    const result = await repartirEnvio(
      operationId,
      rows.map((row, index) => ({ service: row.service, amountGyd: amounts[index]! })),
    );
    setPending(false);
    if (!result.ok) {
      setError(t("splitDeposit.failed", { message: result.error }));
      return;
    }
    toast.success(t("splitDeposit.saved"));
    onDone();
  }

  return (
    <form onSubmit={handleSubmit} onKeyDown={cancelOnEscape(onCancel)} className={EDIT_AREA}>
      {rows.map((row) => (
        <div key={row.key} className="grid grid-cols-[1fr_6rem_auto] items-center gap-x-2">
          <Select
            id={`split-service-${row.key}`}
            value={row.service}
            disabled={pending}
            onValueChange={(value) => updateRow(row.key, { service: value ?? "" })}
          >
            <SelectTrigger className={UNDERLINE_SELECT_TRIGGER} aria-label={t("splitDeposit.service")}>
              {/* Base UI paints the raw value unless it is given the label. */}
              <SelectValue placeholder={t("serviceChange.choose")}>
                {(value) => (value ? serviceName(value as string) : t("serviceChange.choose"))}
              </SelectValue>
            </SelectTrigger>
            <SelectContent>
              {OPERATION_SERVICES.map((option) => (
                <SelectItem key={option} value={option}>
                  {serviceName(option)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <UnderlineInput
            inputMode="decimal"
            aria-label={t("splitDeposit.amount")}
            value={row.amount}
            disabled={pending}
            onChange={(event) => updateRow(row.key, { amount: event.target.value })}
          />
          {rows.length > 1 ? (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={t("splitDeposit.removePart")}
              title={t("splitDeposit.removePart")}
              disabled={pending}
              onClick={() => setRows((current) => current.filter((candidate) => candidate.key !== row.key))}
            >
              <Trash2 aria-hidden="true" />
            </Button>
          ) : (
            <span className="size-6" aria-hidden="true" />
          )}
        </div>
      ))}
      <div className="flex items-center justify-between gap-2">
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          aria-label={t("splitDeposit.addPart")}
          title={t("splitDeposit.addPart")}
          disabled={pending}
          onClick={addRow}
        >
          <Plus aria-hidden="true" />
        </Button>
        <p
          className={`text-xs ${cents(assigned) === cents(total) ? "text-muted-foreground" : "text-destructive"}`}
          aria-live="polite"
        >
          {t("splitDeposit.assigned", { assigned: formatNumber(assigned), total: formatNumber(total) })}
        </p>
      </div>
      <div className="flex items-center gap-2">
        {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
        <ConfirmCancelButtons
          type="submit"
          onCancel={onCancel}
          pending={pending}
          confirmDisabled={!valid}
          confirmLabel={t("splitDeposit.confirm")}
        />
      </div>
    </form>
  );
}
