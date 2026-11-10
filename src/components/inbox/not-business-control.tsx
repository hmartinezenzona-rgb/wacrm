"use client";

import { useCallback, useState } from "react";
import { BellOff, Loader2, Undo2 } from "lucide-react";
import { toast } from "sonner";
import { useTranslations } from "next-intl";
import { createClient } from "@/lib/supabase/client";

export interface NotBusinessPatch {
  not_business_at: string | null;
  not_business_by: string | null;
}

interface NotBusinessProps {
  conversationId: string;
  /** `conversations.not_business_at` — set while the chat is marked "not business". */
  notBusinessAt?: string | null;
  /** Called with the new state after the RPC succeeds, so the parent patches its conversation. */
  onChange: (patch: NotBusinessPatch) => void;
}

/**
 * Calls crm_marcar_no_negocio (migration 364). The RPC re-checks that the caller is an agent of the
 * conversation's account; a customer message reactivates the chat on its own (trigger on messages).
 */
function useNotBusiness({ conversationId, onChange }: NotBusinessProps) {
  const t = useTranslations("Inbox.notBusiness");
  const [busy, setBusy] = useState(false);

  const set = useCallback(
    async (value: boolean) => {
      setBusy(true);
      try {
        const { data, error } = await createClient().rpc("crm_marcar_no_negocio", {
          p_conversation_id: conversationId,
          p_no_negocio: value,
        });
        if (error) {
          console.error("Failed to change the not-business mark:", error.message);
          toast.error(t("failed"));
          return;
        }
        const row = data as { not_business_at?: string | null; not_business_by?: string | null } | null;
        onChange({
          not_business_at: row?.not_business_at ?? null,
          not_business_by: row?.not_business_by ?? null,
        });
      } finally {
        setBusy(false);
      }
    },
    [conversationId, onChange, t],
  );

  return { t, busy, set };
}

/** Header action: mark the chat as not business. Renders nothing once it is marked (the banner takes over). */
export function NotBusinessButton(props: NotBusinessProps) {
  const { t, busy, set } = useNotBusiness(props);
  if (props.notBusinessAt) return null;
  return (
    <button
      type="button"
      onClick={() => void set(true)}
      disabled={busy}
      title={t("markHint")}
      className="inline-flex h-7 items-center justify-center gap-1 rounded-md px-2 text-xs text-muted-foreground hover:bg-muted disabled:opacity-60"
    >
      {busy ? <Loader2 className="h-3 w-3 animate-spin" /> : <BellOff className="h-3 w-3" />}
      <span className="hidden sm:inline">{t("mark")}</span>
    </button>
  );
}

/** Visible state under the header while the chat is marked, with the way back. */
export function NotBusinessBanner(props: NotBusinessProps) {
  const { t, busy, set } = useNotBusiness(props);
  if (!props.notBusinessAt) return null;
  return (
    <div className="flex items-center justify-between gap-3 border-b border-border bg-muted/60 px-4 py-2 text-xs text-muted-foreground">
      <span className="flex min-w-0 items-center gap-2">
        <BellOff className="h-3.5 w-3.5 shrink-0" />
        <span>{t("banner")}</span>
      </span>
      <button
        type="button"
        onClick={() => void set(false)}
        disabled={busy}
        className="inline-flex shrink-0 items-center gap-1 rounded-md px-2 py-1 font-medium text-primary hover:bg-muted disabled:opacity-60"
      >
        {busy ? <Loader2 className="h-3 w-3 animate-spin" /> : <Undo2 className="h-3 w-3" />}
        {t("reactivate")}
      </button>
    </div>
  );
}
