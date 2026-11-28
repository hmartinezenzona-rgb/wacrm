"use client";

import { Clock } from "lucide-react";
import { useTranslations } from "next-intl";

import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/use-auth";
import { canManageMembers } from "@/lib/auth/roles";
import { useAwayMode } from "@/components/layout/away-mode-provider";

/**
 * Pinned notice for every member while an absence is active. Only
 * owners/admins can end it early (the API enforces the same rule).
 */
export function AwayBanner() {
  const t = useTranslations("AwayMode");
  const { accountRole } = useAuth();
  const { ausencia, clear } = useAwayMode();

  if (!ausencia) return null;

  return (
    <div
      role="status"
      className="flex flex-wrap items-center gap-x-2 gap-y-1 border-b border-status-attention/30 bg-status-attention-soft px-4 py-2 text-sm text-status-attention sm:px-6"
    >
      <Clock className="size-4 shrink-0" aria-hidden />
      <span className="font-semibold">{t("banner.active", { when: ausencia.hasta_texto })}</span>
      <span className="min-w-0 break-words">
        · {ausencia.motivo} · {t("banner.by", { name: ausencia.por })}
      </span>
      {accountRole && canManageMembers(accountRole) ? (
        <Button
          variant="ghost"
          size="sm"
          type="button"
          className="ml-auto font-semibold underline"
          onClick={() => void clear()}
        >
          {t("banner.returned")}
        </Button>
      ) : null}
    </div>
  );
}
