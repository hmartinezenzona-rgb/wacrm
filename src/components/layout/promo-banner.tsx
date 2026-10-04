"use client";

import { Check, Loader2, Percent, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/use-auth";
import { usePromoPendiente } from "@/hooks/use-promo-pendiente";
import { canManageMembers } from "@/lib/auth/roles";

/**
 * Pinned notice, shown on every dashboard page while an ETECSA promo waits
 * for a decision. Only owners/admins see it (agents and viewers cannot
 * decide); an unknown role falls back to showing it, the API is the gate.
 */
export function PromoBanner() {
  const { accountRole } = useAuth();
  const { promo, checked, action, confirm, discard } = usePromoPendiente();

  if (accountRole && !canManageMembers(accountRole)) return null;
  if (!checked || !promo) return null;

  return (
    <div
      role="status"
      className="flex flex-wrap items-center justify-between gap-2 border-b border-amber-300/60 bg-amber-50 px-4 py-2 text-amber-950 dark:border-amber-500/30 dark:bg-amber-950/40 dark:text-amber-100 sm:px-6"
    >
      <p className="flex min-w-0 items-center gap-2 text-sm font-medium">
        <Percent className="h-4 w-4 shrink-0" />
        <span className="min-w-0 break-words">
          Promoción Etecsa: {promo.resumen}
          {!promo.hay_precio && " (sin precio)"}
        </span>
      </p>
      <div className="flex shrink-0 items-center gap-2">
        <Button
          size="sm"
          disabled={action !== null || !promo.hay_precio}
          onClick={confirm}
          title={
            promo.hay_precio
              ? "Permitir que el bot use esta promoción"
              : "Define primero el precio de esta recarga"
          }
        >
          {action === "confirm" ? (
            <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
          ) : (
            <Check className="mr-1.5 h-4 w-4" />
          )}
          Confirmar
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={action !== null}
          onClick={discard}
          title="No permitir que el bot use esta promoción"
        >
          {action === "discard" ? (
            <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
          ) : (
            <X className="mr-1.5 h-4 w-4" />
          )}
          Descartar
        </Button>
      </div>
    </div>
  );
}
