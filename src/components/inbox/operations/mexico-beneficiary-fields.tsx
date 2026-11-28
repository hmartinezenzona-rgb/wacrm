"use client";

import { useTranslations } from "next-intl";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { FieldRow, UNDERLINE_SELECT_TRIGGER, UnderlineInput } from "./edit-form-fields";
import { MEXICO_WITHDRAWAL_BANKS, type MexicoBeneficiaryType } from "@/lib/remittance-operations/mexico";

interface MexicoBeneficiaryFieldsProps {
  type: MexicoBeneficiaryType;
  onTypeChange: (type: MexicoBeneficiaryType) => void;
  name: string;
  onNameChange: (value: string) => void;
  /** A bank account's CLABE. */
  clabe: string;
  onClabeChange: (value: string) => void;
  /** A bank account's bank, typed. */
  bankName: string;
  onBankNameChange: (value: string) => void;
  /** A cardless withdrawal's network, picked from Coppel or BBVA. */
  withdrawalBank: string;
  onWithdrawalBankChange: (value: string) => void;
  /** A cardless withdrawal's phone. */
  phone: string;
  onPhoneChange: (value: string) => void;
  /** The USD that goes to this recipient (optional). */
  amount: string;
  onAmountChange: (value: string) => void;
  disabled: boolean;
}

/** The fields of a México recipient: a bank account (holder, CLABE, bank) or a cardless withdrawal (receiver, network,
 *  phone), chosen by the type picker. Presentational: the add control owns the state and the request. */
export function MexicoBeneficiaryFields(props: MexicoBeneficiaryFieldsProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const isAccount = props.type === "mexico_cuenta";

  return (
    <>
      <FieldRow label={t("beneficiaryTypeLabel")} htmlFor="add-beneficiary-type">
        <Select
          id="add-beneficiary-type"
          value={props.type}
          disabled={props.disabled}
          onValueChange={(value) => props.onTypeChange((value ?? "mexico_cuenta") as MexicoBeneficiaryType)}
        >
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            <SelectValue>{(value) => (value === "mexico_retiro" ? t("mexicoWithdrawal") : t("mexicoAccount"))}</SelectValue>
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="mexico_cuenta">{t("mexicoAccount")}</SelectItem>
            <SelectItem value="mexico_retiro">{t("mexicoWithdrawal")}</SelectItem>
          </SelectContent>
        </Select>
      </FieldRow>

      <FieldRow label={t("name")} htmlFor="add-beneficiary-name">
        <UnderlineInput id="add-beneficiary-name" value={props.name} onChange={(event) => props.onNameChange(event.target.value)} />
      </FieldRow>

      {isAccount ? (
        <>
          <FieldRow label={t("clabe")} htmlFor="add-beneficiary-clabe">
            <UnderlineInput
              id="add-beneficiary-clabe"
              inputMode="numeric"
              value={props.clabe}
              onChange={(event) => props.onClabeChange(event.target.value)}
            />
          </FieldRow>
          <FieldRow label={t("bank")} htmlFor="add-beneficiary-bank">
            <UnderlineInput id="add-beneficiary-bank" value={props.bankName} onChange={(event) => props.onBankNameChange(event.target.value)} />
          </FieldRow>
        </>
      ) : (
        <>
          <FieldRow label={t("bank")} htmlFor="add-beneficiary-bank">
            <Select
              id="add-beneficiary-bank"
              value={props.withdrawalBank}
              disabled={props.disabled}
              onValueChange={(value) => props.onWithdrawalBankChange(value ?? MEXICO_WITHDRAWAL_BANKS[0])}
            >
              <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {MEXICO_WITHDRAWAL_BANKS.map((bank) => (
                  <SelectItem key={bank} value={bank}>
                    {bank}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </FieldRow>
          <FieldRow label={t("phone")} htmlFor="add-beneficiary-phone">
            <UnderlineInput
              id="add-beneficiary-phone"
              inputMode="numeric"
              value={props.phone}
              onChange={(event) => props.onPhoneChange(event.target.value)}
            />
          </FieldRow>
        </>
      )}

      <FieldRow label={t("amountUsd")} htmlFor="add-beneficiary-amount">
        <UnderlineInput
          id="add-beneficiary-amount"
          inputMode="decimal"
          value={props.amount}
          onChange={(event) => props.onAmountChange(event.target.value)}
        />
      </FieldRow>
    </>
  );
}
