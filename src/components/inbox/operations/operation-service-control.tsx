"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { cambiarServicio } from "@/lib/remittance-operations/commands";
import { OPERATION_SERVICES, isOperationService, type OperationService } from "@/lib/remittance-operations/services";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

/**
 * The service an operation currently has, as the selector names it: recarga/combo/visa by service type, otherwise
 * the delivery method, otherwise the type of its first current recipient. `null` when none of them names a service
 * (e.g. a deposit-only remesa), so the selector starts on its placeholder.
 */
export function currentServiceOf(
  operation: Pick<RemittanceOperationRead, "serviceType" | "deliveryMethod" | "beneficiaries">,
): OperationService | null {
  if (operation.serviceType === "recarga" || operation.serviceType === "combo" || operation.serviceType === "visa") {
    return operation.serviceType;
  }
  if (isOperationService(operation.deliveryMethod)) return operation.deliveryMethod;
  const first = operation.beneficiaries[0]?.beneficiaryType;
  return isOperationService(first) ? first : null;
}

interface OperationServiceControlProps {
  operationId: string;
  /** The service the operation has now, `null` when unknown. */
  current: OperationService | null;
  /** Called after a successful change, so the panel refetches. */
  onDone: () => void;
}

/**
 * "Servicio" selector of an open operation. Choosing another service does not send anything: it asks for a
 * confirmation that says what changes (quote recalculated, recipients that do not fit removed, customer not
 * messaged). The card decides who sees this (editable, open operations); the API and RPC re-check role and status.
 */
export function OperationServiceControl({ operationId, current, onDone }: OperationServiceControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [selected, setSelected] = useState<string>(current ?? "");
  const [pending, setPending] = useState(false);

  const changing = selected !== "" && selected !== (current ?? "");
  const selectId = `operation-service-${operationId}`;

  async function confirm() {
    setPending(true);
    const result = await cambiarServicio(operationId, selected);
    setPending(false);
    if (!result.ok) {
      toast.error(t("serviceChange.failed", { message: result.error }));
      setSelected(current ?? "");
      return;
    }
    toast.success(t("serviceChange.saved"));
    onDone();
  }

  return (
    <div className="space-y-1.5 rounded-md border border-border bg-muted/40 p-2">
      <div className="flex items-center gap-2">
        <Label htmlFor={selectId} className="shrink-0">
          {t("serviceChange.label")}
        </Label>
        <select
          id={selectId}
          value={selected}
          disabled={pending}
          onChange={(event) => setSelected(event.target.value)}
          className="h-8 min-w-0 flex-1 rounded-md border border-input bg-background px-2 text-sm"
        >
          {current === null && (
            <option value="" disabled>
              {t("serviceChange.choose")}
            </option>
          )}
          {OPERATION_SERVICES.map((service) => (
            <option key={service} value={service}>
              {t(`closing.method.${service}`)}
            </option>
          ))}
        </select>
      </div>

      {changing && (
        <>
          <p className="text-xs text-muted-foreground">{t("serviceChange.warning")}</p>
          <div className="flex justify-end gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={pending}
              onClick={() => setSelected(current ?? "")}
            >
              {t("cancel")}
            </Button>
            <Button type="button" size="sm" disabled={pending} onClick={() => void confirm()}>
              {t("serviceChange.confirm")}
            </Button>
          </div>
        </>
      )}
    </div>
  );
}
