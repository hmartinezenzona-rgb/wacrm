"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldRow, UNDERLINE_SELECT_TRIGGER } from "./edit-form-fields";
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
    <div className={EDIT_AREA} onKeyDown={cancelOnEscape(onCancel)}>
      <FieldRow label={t("selectTarget")} htmlFor="beneficiary-reassign-target">
        <Select
          id="beneficiary-reassign-target"
          value={targetOperationId}
          disabled={pending}
          onValueChange={(value) => setTargetOperationId(value ?? "")}
        >
          <SelectTrigger className={UNDERLINE_SELECT_TRIGGER}>
            {/* Base UI paints the raw value unless it is given the label. */}
            <SelectValue placeholder={t("selectTarget")}>
              {(value) => targets.find((target) => target.id === value)?.label ?? t("selectTarget")}
            </SelectValue>
          </SelectTrigger>
          <SelectContent>
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
          onCancel={onCancel}
          onConfirm={handleConfirm}
          confirmLabel={t("confirmMove")}
          pending={pending}
          confirmDisabled={!targetOperationId}
        />
      </div>
    </div>
  );
}
