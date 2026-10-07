"use client";

import { useEffect, useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldPair, FieldRow, PairCell, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import type { CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { cambiarServicio, corregirOperacion, fetchCalculatorRates } from "@/lib/remittance-operations/commands";
import { destinationCurrencyOf, previewDestinationAmount } from "@/lib/remittance-operations/destination-quote";
import { OPERATION_SERVICES, currentServiceOf } from "@/lib/remittance-operations/services";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

interface OperationCorrectionFormProps {
  operation: RemittanceOperationRead;
  onDone: () => void;
  onCancel: () => void;
}

/**
 * Inline correction form for an operation: service, deposit (GYD), destination amount and deposit method.
 * The service decides the destination currency and the delivery method (`cambiarServicio` sets both), so neither is
 * an input; the destination amount shows its currency as a suffix and, when the service or the deposit changes, shows
 * the amount at that service's rate (rates read from /api/calculator/rates; the database recomputes it on save).
 * A destination amount the person types wins and is the only one sent: otherwise it is left to the database, so
 * nothing gets locked to a stale number. Sends only the fields the agent changed, snake_case, amounts as numbers.
 * The service goes through its own command and runs first, because it recalculates the quote the other corrections
 * may then adjust. Confirmed with the check, cancelled with the X (as the closing control).
 */
export function OperationCorrectionForm({ operation, onDone, onCancel }: OperationCorrectionFormProps) {
  const t = useTranslations("Inbox.operationsPanel");

  const initialService = currentServiceOf(operation) ?? "";
  const initialDepositMethod = operation.depositMethod ?? "";
  const initialQuotedSourceAmount =
    operation.quotedSourceAmount === null ? "" : String(operation.quotedSourceAmount);
  const initialQuotedDestinationAmount =
    operation.quotedDestinationAmount === null ? "" : String(operation.quotedDestinationAmount);

  const [service, setService] = useState<string>(initialService);
  const [depositMethod, setDepositMethod] = useState(initialDepositMethod);
  const [quotedSourceAmount, setQuotedSourceAmount] = useState(initialQuotedSourceAmount);
  // Only a value the person typed; empty means "not typed": the shown amount is then derived.
  const [typedDestinationAmount, setTypedDestinationAmount] = useState("");
  const [rates, setRates] = useState<CalculatorRates | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchCalculatorRates()
      .then((loaded) => {
        if (!cancelled) setRates(loaded);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  const serviceChanged = service !== "" && service !== initialService;
  const depositChanged = quotedSourceAmount !== initialQuotedSourceAmount;
  const destinationCurrency = destinationCurrencyOf(service);
  const preview =
    serviceChanged || depositChanged ? previewDestinationAmount(service, Number(quotedSourceAmount), rates) : null;
  const destinationLocked = Boolean(operation.adminLockedFields?.quoted_destination_amount);
  const typed =
    destinationCurrency !== null &&
    typedDestinationAmount !== "" &&
    (typedDestinationAmount !== initialQuotedDestinationAmount || serviceChanged || depositChanged);
  const shownDestinationAmount = typed
    ? typedDestinationAmount
    : serviceChanged || depositChanged
      ? preview === null
        ? ""
        : String(preview)
      : initialQuotedDestinationAmount;

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    const changes: Record<string, unknown> = {};

    if (depositMethod !== initialDepositMethod) {
      changes.deposit_method = depositMethod;
    }

    if (depositChanged) {
      const amount = Number(quotedSourceAmount);
      if (!(amount > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      changes.quoted_source_amount = amount;
    }

    if (typed) {
      const amount = Number(typedDestinationAmount);
      if (!(amount > 0)) {
        setError(t("invalidAmount"));
        return;
      }
      changes.quoted_destination_amount = amount;
    } else if (depositChanged && !serviceChanged && destinationLocked && preview !== null) {
      // A manual lock on the destination (an earlier correction) would keep the old amount against the new deposit
      // (changing the service releases it, a deposit change alone does not): send the recalculation shown instead.
      changes.quoted_destination_amount = preview;
    }

    if (!serviceChanged && Object.keys(changes).length === 0) {
      setError(t("noChanges"));
      return;
    }

    setPending(true);

    if (serviceChanged) {
      const changed = await cambiarServicio(operation.id, service);
      if (!changed.ok) {
        setPending(false);
        toast.error(t("serviceChange.failed", { message: changed.error }));
        setService(initialService);
        return;
      }
      toast.success(t("serviceChange.saved"));
    }

    if (Object.keys(changes).length > 0) {
      const result = await corregirOperacion(operation.id, changes);
      if (!result.ok) {
        setPending(false);
        if (serviceChanged) {
          // The service is already saved: report the rest and refresh, so the form reopens on what is stored now.
          toast.error(result.error);
          onDone();
        } else {
          setError(result.error);
        }
        return;
      }
    }

    setPending(false);
    onDone();
  }

  const depositInput = (
    <UnderlineInput
      id="operation-quoted-source-amount"
      value={quotedSourceAmount}
      onChange={(event) => setQuotedSourceAmount(event.target.value)}
    />
  );

  return (
    <form onSubmit={handleSubmit} onKeyDown={cancelOnEscape(onCancel)} className={EDIT_AREA}>
      <FieldRow label={t("serviceChange.label")} htmlFor="operation-service">
        <Select id="operation-service" value={service} disabled={pending} onValueChange={(v) => setService(v ?? "")}>
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            {/* Base UI paints the raw value unless it is given the label. */}
            <SelectValue placeholder={t("serviceChange.choose")}>
              {(v) => (v ? t(`closing.method.${v as string}`) : t("serviceChange.choose"))}
            </SelectValue>
          </SelectTrigger>
          <SelectContent>
            {OPERATION_SERVICES.map((option) => (
              <SelectItem key={option} value={option}>
                {t(`closing.method.${option}`)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FieldRow>
      {destinationCurrency === null ? (
        <FieldRow label={t("quotedSourceAmount")} htmlFor="operation-quoted-source-amount">
          {depositInput}
        </FieldRow>
      ) : (
        <FieldPair>
          <PairCell label={t("quotedSourceAmount")} htmlFor="operation-quoted-source-amount">
            {depositInput}
          </PairCell>
          <PairCell label={t("quotedDestinationAmount")} htmlFor="operation-quoted-destination-amount">
            <div className="flex items-center gap-1">
              <UnderlineInput
                id="operation-quoted-destination-amount"
                value={shownDestinationAmount}
                placeholder={shownDestinationAmount === "" && (serviceChanged || depositChanged) ? t("recalculatedOnSave") : undefined}
                onChange={(event) => setTypedDestinationAmount(event.target.value)}
              />
              <span data-testid="destination-currency" className="shrink-0 text-xs font-medium text-muted-foreground">
                {destinationCurrency}
              </span>
            </div>
          </PairCell>
        </FieldPair>
      )}
      <FieldRow label={t("depositMethod")} htmlFor="operation-deposit-method">
        <UnderlineInput
          id="operation-deposit-method"
          value={depositMethod}
          onChange={(event) => setDepositMethod(event.target.value)}
        />
      </FieldRow>

      <div className="flex items-center gap-2">
        {error && <p className="min-w-0 flex-1 text-xs text-destructive">{error}</p>}
        <ConfirmCancelButtons type="submit" onCancel={onCancel} pending={pending} />
      </div>
    </form>
  );
}
