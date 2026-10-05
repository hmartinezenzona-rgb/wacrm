"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Banknote, Check, Landmark, ShoppingBasket, Smartphone, Stamp, TreePalm, X, type LucideIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cerrarOperacionManual, eliminarOperacion } from "@/lib/remittance-operations/commands";
import { NotifyToggle } from "./notify-toggle";
import { MethodIcon } from "./operation-icons";

/** Clásica, Tropical, cash, recharge, combo and visa share one "cash" kind in MethodIcon (the cards show them alike); the service picker
 *  must tell them apart, so they get their own icons here. CUP card and Zelle keep the cards' icons. */
const PICKER_ICON: Partial<Record<string, { Icon: LucideIcon; className: string }>> = {
  clasica: { Icon: Landmark, className: "text-indigo-600 dark:text-indigo-300" },
  tropical: { Icon: TreePalm, className: "text-emerald-600 dark:text-emerald-300" },
  efectivo_usd: { Icon: Banknote, className: "text-amber-600 dark:text-amber-300" },
  recarga: { Icon: Smartphone, className: "text-rose-600 dark:text-rose-300" },
  combo: { Icon: ShoppingBasket, className: "text-sky-600 dark:text-sky-300" },
  visa: { Icon: Stamp, className: "text-violet-600 dark:text-violet-300" },
};

const SERVICES = ["cuban_card", "zelle", "clasica", "tropical", "efectivo_usd", "recarga", "combo", "visa"] as const;

interface OperationClosingControlProps {
  operationId: string;
  /** `close` completes a verified remesa (customer messaged only if the
   *  bell is on); `delete` soft-deletes it. Neither asks for a reason. */
  kind: "close" | "delete";
  onDone: () => void;
  onCancel: () => void;
  /** Close only: the remesa has no beneficiary and no delivery method, so the
   *  calculator needs the service picked before the close can be confirmed. */
  needsService?: boolean;
}

/**
 * Inline confirmation for the owner/admin closing actions (migrations
 * 190/191): a short warning and icon-only buttons (green check confirms, X
 * cancels). Closing also shows the notify-customer bell, off by default.
 * The server re-checks role and status, so a refusal (e.g. a remesa holding
 * a consumed deposit) surfaces here as its message.
 */
export function OperationClosingControl({ operationId, kind, onDone, onCancel, needsService = false }: OperationClosingControlProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [notify, setNotify] = useState(false);
  const [service, setService] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isClose = kind === "close";
  const askService = isClose && needsService;
  const confirmLabel = isClose ? t("closing.closeConfirm") : t("closing.deleteConfirm");

  async function handleConfirm() {
    setError(null);
    setPending(true);
    const result = isClose
      ? await (askService && service
          ? cerrarOperacionManual(operationId, notify, service)
          : cerrarOperacionManual(operationId, notify))
      : await eliminarOperacion(operationId);
    setPending(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }
    onDone();
  }

  return (
    <div className="space-y-1.5 rounded-md border border-border bg-muted/40 p-2">
      {error && <p className="text-xs text-destructive">{error}</p>}

      {askService && (
        <div className="flex items-center justify-end gap-1">
          {SERVICES.map((method) => {
            const label = t(`closing.method.${method}`);
            const selected = service === method;
            return (
              <Button
                key={method}
                type="button"
                variant="outline"
                size="icon-sm"
                aria-label={label}
                title={label}
                aria-pressed={selected}
                disabled={pending}
                className={selected ? "border-green-600 bg-green-50 ring-2 ring-green-600 dark:bg-green-500/15" : "opacity-70"}
                onClick={() => setService(method)}
              >
                {(() => {
                  const own = PICKER_ICON[method];
                  return own ? (
                    <span role="img" aria-label={label} className="inline-flex">
                      <own.Icon className={`size-4 ${own.className}`} aria-hidden="true" />
                    </span>
                  ) : (
                    <MethodIcon method={method} label={label} />
                  );
                })()}
              </Button>
            );
          })}
        </div>
      )}

      <div className="flex items-center justify-end gap-1">
        {isClose && <NotifyToggle notify={notify} onChange={setNotify} disabled={pending} />}
        <Button
          type="button"
          variant="outline"
          size="icon-sm"
          aria-label={t("cancel")}
          title={t("cancel")}
          onClick={onCancel}
          disabled={pending}
        >
          <X aria-hidden="true" />
        </Button>
        <Button
          type="button"
          size="icon-sm"
          aria-label={confirmLabel}
          title={confirmLabel}
          className="bg-green-600 text-white hover:bg-green-700"
          disabled={pending || (askService && service === null)}
          onClick={handleConfirm}
        >
          <Check aria-hidden="true" />
        </Button>
      </div>
    </div>
  );
}
