"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { quitarBeneficiario } from "@/lib/remittance-operations/commands";

interface BeneficiaryRemoveControlProps {
  beneficiaryId: string;
  onDone: () => void;
  onCancel: () => void;
}

/**
 * Inline confirmation to take a current recipient off an open operation (migration 377). The recipient stays in the history as
 * `reemplazado` and the removal is audited, so the warning says it can be added again. The server re-checks role and status, so a
 * refusal (for example a closed operation) surfaces here as its message.
 */
export function BeneficiaryRemoveControl({ beneficiaryId, onDone, onCancel }: BeneficiaryRemoveControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConfirm() {
    setError(null);
    setPending(true);
    const result = await quitarBeneficiario(beneficiaryId);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    onDone();
  }

  return (
    <div className="space-y-1 border-l-2 border-border pl-2" onKeyDown={cancelOnEscape(onCancel)}>
      <p className="text-xs text-muted-foreground">{t("removeBeneficiaryWarning")}</p>
      {error && <p className="text-xs text-destructive">{error}</p>}
      <ConfirmCancelButtons
        onCancel={onCancel}
        onConfirm={handleConfirm}
        confirmLabel={t("confirmRemoveBeneficiary")}
        pending={pending}
      />
    </div>
  );
}
