"use client";

import { useTranslations } from "next-intl";
import { Building2, Landmark, UserRound } from "lucide-react";
import type { RemittanceBeneficiaryRead } from "@/lib/remittance-operations/types";
import { formatClabe } from "@/lib/remittance-operations/mexico";
import { CopyChip } from "./copy-chip";

/** The México rows of one recipient on an operation card: the holder or receiver name, the CLABE (bank accounts
 *  only, copied whole), and the bank. The phone and the other rows are the card's own. */
export function MexicoRecipientRows({ beneficiary }: { beneficiary: RemittanceBeneficiaryRead }) {
  const t = useTranslations("Inbox.operationsPanel");
  const isAccount = beneficiary.beneficiaryType === "mexico_cuenta";

  return (
    <>
      {beneficiary.name && (
        <CopyChip
          value={beneficiary.name}
          display={<span className="font-sans text-sm font-medium">{beneficiary.name}</span>}
          icon={<UserRound className="size-3.5" aria-hidden="true" />}
          ariaLabel={t("copyValue", { label: t("name") })}
        />
      )}
      {isAccount && beneficiary.clabe && (
        <CopyChip
          value={beneficiary.clabe}
          display={formatClabe(beneficiary.clabe)}
          icon={<Landmark className="size-3.5" aria-hidden="true" />}
          ariaLabel={t("copyValue", { label: t("clabe") })}
        />
      )}
      {beneficiary.bankName && (
        <p className="flex items-center gap-2 px-2 text-xs font-medium text-muted-foreground">
          <Building2 className="size-3.5" aria-hidden="true" />
          {beneficiary.bankName}
        </p>
      )}
    </>
  );
}
