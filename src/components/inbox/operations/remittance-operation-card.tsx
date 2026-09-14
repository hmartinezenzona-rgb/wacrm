"use client";

import { useTranslations } from "next-intl";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

interface RemittanceOperationCardProps {
  operation: RemittanceOperationRead;
}

function money(amount: number | null, currency: string | null): string | null {
  if (amount === null) return null;
  const formatted = new Intl.NumberFormat("en-US").format(amount);
  return currency ? `${formatted} ${currency}` : formatted;
}

/**
 * Presentational, read-only. One open remesa operation: amount(s),
 * delivery method, status, and every current ('vigente') beneficiary
 * with masked card/phone. No correction, verify, or delivery affordances
 * — those are Slices 6-8.
 */
export function RemittanceOperationCard({ operation }: RemittanceOperationCardProps) {
  const t = useTranslations("Inbox.operationsPanel");
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

      {operation.deliveryMethod && (
        <p className="text-xs text-muted-foreground">
          {t("deliveryMethod")}: {operation.deliveryMethod}
        </p>
      )}

      <div>
        <h4 className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
          {t("beneficiaries")}
        </h4>
        {operation.beneficiaries.length === 0 ? (
          <p className="mt-1 text-xs text-muted-foreground">{t("noBeneficiaries")}</p>
        ) : (
          <ul className="mt-1 space-y-1.5">
            {operation.beneficiaries.map((beneficiary) => {
              const beneficiaryAmount = money(beneficiary.amount, beneficiary.currency);
              return (
                <li key={beneficiary.id} className="rounded-md bg-muted px-2 py-1.5 text-xs">
                  <p className="font-medium text-foreground">
                    {beneficiary.name ?? t("beneficiaryNameUnavailable")}
                  </p>
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
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </article>
  );
}
