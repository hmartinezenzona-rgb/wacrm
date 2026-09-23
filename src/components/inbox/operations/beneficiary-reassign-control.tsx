"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { reasignarBeneficiario } from "@/lib/remittance-operations/commands";

interface ReassignTarget {
  id: string;
  label: string;
}

interface BeneficiaryReassignControlProps {
  beneficiaryId: string;
  targets: ReassignTarget[];
  onDone: () => void;
  onCancel: () => void;
}

/**
 * Inline control to move a beneficiary to another open operation of the
 * same conversation. Confirm stays disabled until a target is picked.
 */
export function BeneficiaryReassignControl({
  beneficiaryId,
  targets,
  onDone,
  onCancel,
}: BeneficiaryReassignControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [targetOperationId, setTargetOperationId] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConfirm() {
    if (!targetOperationId) return;
    setError(null);
    setPending(true);
    const result = await reasignarBeneficiario(beneficiaryId, targetOperationId);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }

    onDone();
  }

  return (
    <div className="space-y-2 rounded-md border border-border bg-muted/40 p-2">
      <div className="space-y-1">
        <Label htmlFor="beneficiary-reassign-target">{t("selectTarget")}</Label>
        <select
          id="beneficiary-reassign-target"
          value={targetOperationId}
          onChange={(event) => setTargetOperationId(event.target.value)}
          className="h-8 w-full rounded-lg border border-input bg-transparent px-2.5 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
        >
          <option value="">{t("selectTarget")}</option>
          {targets.map((target) => (
            <option key={target.id} value={target.id}>
              {target.label}
            </option>
          ))}
        </select>
      </div>

      {error && <p className="text-xs text-destructive">{error}</p>}

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" size="sm" onClick={onCancel} disabled={pending}>
          {t("cancel")}
        </Button>
        <Button type="button" size="sm" disabled={pending || !targetOperationId} onClick={handleConfirm}>
          {t("confirmMove")}
        </Button>
      </div>
    </div>
  );
}
