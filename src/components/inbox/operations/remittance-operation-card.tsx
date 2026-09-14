"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Lock } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { OperationCorrectionForm } from "./operation-correction-form";
import { BeneficiaryCorrectionForm } from "./beneficiary-correction-form";
import { BeneficiaryReassignControl } from "./beneficiary-reassign-control";

interface ReassignTarget {
  id: string;
  label: string;
}

interface RemittanceOperationCardProps {
  operation: RemittanceOperationRead;
  /** Current user can correct/reassign (role agent or higher). */
  canEdit: boolean;
  /** Other open (non-terminal) remesa operations of the same
   *  conversation, offered as reassignment targets for this card's
   *  beneficiaries. */
  otherOpenOperations: ReassignTarget[];
  /** Called after a correction or reassignment succeeds, so the panel
   *  container can refetch. */
  onChanged: () => void;
}

/** The RPC never returns these (see types.ts), but the correction API can
 *  still move an operation into one of them — defensive, not dead code. */
const TERMINAL_STATUSES: ReadonlyArray<string> = ["completed", "cancelled"];

type OpenFormKind = "operation" | "beneficiary" | "reassign";

interface OpenFormState {
  kind: OpenFormKind;
  beneficiaryId?: string;
}

function money(amount: number | null, currency: string | null): string | null {
  if (amount === null) return null;
  const formatted = new Intl.NumberFormat("en-US").format(amount);
  return currency ? `${formatted} ${currency}` : formatted;
}

/**
 * Presentational: one open remesa operation, amount(s), delivery method,
 * status, every current ('vigente') beneficiary with masked card/phone,
 * admin-lock indicators, and — when `canEdit` and the operation isn't
 * terminal — inline correction and reassignment affordances (Slice 6).
 */
export function RemittanceOperationCard({
  operation,
  canEdit,
  otherOpenOperations,
  onChanged,
}: RemittanceOperationCardProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [openForm, setOpenForm] = useState<OpenFormState | null>(null);

  const editable = canEdit && !TERMINAL_STATUSES.includes(operation.status);
  const isLocked = (key: string) => key in operation.adminLockedFields;

  function toggle(next: OpenFormState) {
    setOpenForm((current) =>
      current && current.kind === next.kind && current.beneficiaryId === next.beneficiaryId ? null : next,
    );
  }

  function handleChanged() {
    setOpenForm(null);
    onChanged();
  }

  const source = money(operation.quotedSourceAmount, operation.sourceCurrency);
  const destination = money(operation.quotedDestinationAmount, operation.destinationCurrency);

  return (
    <article className="space-y-2 rounded-lg border border-border bg-card p-3">
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm font-semibold tabular-nums text-foreground">
          {source ?? t("amountUnavailable")}
          {destination && (
            <>
              {" "}
              <span className="text-muted-foreground">→</span> {destination}
            </>
          )}
        </p>
        <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
          {t(`status.${operation.status}`)}
        </span>
      </div>

      <dl className="grid grid-cols-2 gap-x-2 gap-y-1 text-xs text-muted-foreground">
        <FieldRow
          label={t("destinationCurrency")}
          value={operation.destinationCurrency}
          locked={isLocked("destination_currency")}
          lockLabel={t("lockedByOperator")}
        />
        <FieldRow
          label={t("deliveryMethod")}
          value={operation.deliveryMethod}
          locked={isLocked("delivery_method")}
          lockLabel={t("lockedByOperator")}
        />
        <FieldRow
          label={t("depositMethod")}
          value={operation.depositMethod}
          locked={isLocked("deposit_method")}
          lockLabel={t("lockedByOperator")}
        />
        <FieldRow
          label={t("quotedSourceAmount")}
          value={source}
          locked={isLocked("quoted_source_amount")}
          lockLabel={t("lockedByOperator")}
        />
        <FieldRow
          label={t("quotedDestinationAmount")}
          value={destination}
          locked={isLocked("quoted_destination_amount")}
          lockLabel={t("lockedByOperator")}
        />
      </dl>

      {editable && (
        <Button type="button" variant="outline" size="sm" onClick={() => toggle({ kind: "operation" })}>
          {t("editOperation")}
        </Button>
      )}

      {openForm?.kind === "operation" && (
        <OperationCorrectionForm operation={operation} onDone={handleChanged} onCancel={() => setOpenForm(null)} />
      )}

      <div>
        <h4 className="flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
          {t("beneficiaries")}
          {isLocked("beneficiaries") && <Lock size={12} aria-label={t("lockedByOperator")} />}
        </h4>
        {operation.beneficiaries.length === 0 ? (
          <p className="mt-1 text-xs text-muted-foreground">{t("noBeneficiaries")}</p>
        ) : (
          <ul className="mt-1 space-y-1.5">
            {operation.beneficiaries.map((beneficiary) => {
              const beneficiaryAmount = money(beneficiary.amount, beneficiary.currency);
              const isEditingBeneficiary =
                openForm?.kind === "beneficiary" && openForm.beneficiaryId === beneficiary.id;
              const isMovingBeneficiary =
                openForm?.kind === "reassign" && openForm.beneficiaryId === beneficiary.id;

              return (
                <li key={beneficiary.id} className="rounded-md bg-muted px-2 py-1.5 text-xs">
                  <div className="flex items-center justify-between gap-2">
                    <p className="font-medium text-foreground">
                      {beneficiary.name ?? t("beneficiaryNameUnavailable")}
                    </p>
                    {editable && (
                      <div className="flex shrink-0 gap-1">
                        <Button
                          type="button"
                          variant="ghost"
                          size="xs"
                          onClick={() => toggle({ kind: "beneficiary", beneficiaryId: beneficiary.id })}
                        >
                          {t("editBeneficiary")}
                        </Button>
                        {otherOpenOperations.length > 0 && (
                          <Button
                            type="button"
                            variant="ghost"
                            size="xs"
                            onClick={() => toggle({ kind: "reassign", beneficiaryId: beneficiary.id })}
                          >
                            {t("moveBeneficiary")}
                          </Button>
                        )}
                      </div>
                    )}
                  </div>
                  <dl className="mt-0.5 space-y-0.5 text-muted-foreground">
                    {beneficiary.cardNumberMasked && (
                      <div className="flex justify-between gap-2">
                        <dt>{t("card")}</dt>
                        <dd className="font-medium tabular-nums text-foreground">
                          {beneficiary.cardNumberMasked}
                        </dd>
                      </div>
                    )}
                    {beneficiary.phoneMasked && (
                      <div className="flex justify-between gap-2">
                        <dt>{t("phone")}</dt>
                        <dd className="font-medium tabular-nums text-foreground">
                          {beneficiary.phoneMasked}
                        </dd>
                      </div>
                    )}
                    {beneficiary.zelleAccount && (
                      <div className="flex justify-between gap-2">
                        <dt>{t("zelleAccount")}</dt>
                        <dd className="font-medium text-foreground">{beneficiary.zelleAccount}</dd>
                      </div>
                    )}
                    {beneficiaryAmount && (
                      <div className="flex justify-between gap-2">
                        <dt>{t("amount")}</dt>
                        <dd className="font-medium tabular-nums text-foreground">{beneficiaryAmount}</dd>
                      </div>
                    )}
                  </dl>
                  {isEditingBeneficiary && (
                    <div className="mt-1.5">
                      <BeneficiaryCorrectionForm
                        beneficiary={beneficiary}
                        onDone={handleChanged}
                        onCancel={() => setOpenForm(null)}
                      />
                    </div>
                  )}
                  {isMovingBeneficiary && (
                    <div className="mt-1.5">
                      <BeneficiaryReassignControl
                        beneficiaryId={beneficiary.id}
                        targets={otherOpenOperations}
                        onDone={handleChanged}
                        onCancel={() => setOpenForm(null)}
                      />
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </article>
  );
}

function FieldRow({
  label,
  value,
  locked,
  lockLabel,
}: {
  label: string;
  value: string | null;
  locked: boolean;
  lockLabel: string;
}) {
  return (
    <div className="flex items-center gap-1">
      <dt>{label}:</dt>
      <dd className="font-medium text-foreground">{value ?? "—"}</dd>
      {locked && <Lock size={12} aria-label={lockLabel} />}
    </div>
  );
}
