"use client";

import { useCallback, useEffect, useState } from "react";
import { setInboxOpenTarget } from "@/lib/inbox/open-target";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { usePromoPendiente } from "@/hooks/use-promo-pendiente";
import type { Notification } from "@/types";
import {
  AlertTriangle,
  Bell,
  CheckCheck,
  Loader2,
  MessageSquareX,
  Percent,
  ClipboardList,
  Trash2,
  X,
  XCircle,
  UserPlus,
} from "lucide-react";
import { formatDistanceToNow } from "date-fns";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { cn } from "@/lib/utils";
import { toast } from "sonner";
import { PageHeader, PageShell } from "@/components/layout/page-header";
import { EmptyState } from "@/components/ui/empty-state";

// Icon per notification type. Only one type existed at first
// (conversation_assigned) but this keeps future types a one-line add.
const TYPE_ICON: Record<Notification["type"], typeof Bell> = {
  conversation_assigned: UserPlus,
  deal_incidencia: AlertTriangle,
  mensaje_fallido: MessageSquareX,
  promo_etecsa: Percent,
  resumen_diario: ClipboardList,
};

export default function NotificationsPage() {
  const router = useRouter();
  const t = useTranslations("Notifications");
  const { accountId, user } = useAuth();
  const [notifications, setNotifications] = useState<Notification[] | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);
  const [markingAll, setMarkingAll] = useState(false);
  const [confirmAllOpen, setConfirmAllOpen] = useState(false);
  const [deletingAll, setDeletingAll] = useState(false);
  const {
    promo: promoPendiente,
    checked: promoChecked,
    action: promoAction,
    confirm: confirmPromo,
    discard: discardPromo,
  } = usePromoPendiente();

  const load = useCallback(async () => {
    if (!accountId) return;
    const supabase = createClient();
    const { data, error: fetchErr } = await supabase
      .from("notifications")
      .select("*")
      .eq("account_id", accountId)
      .order("created_at", { ascending: false })
      .limit(100);
    if (fetchErr) {
      setError(fetchErr.message);
      return;
    }
    setNotifications((data ?? []) as Notification[]);
  }, [accountId]);

  useEffect(() => {
    load();
  }, [load]);

  // Realtime — new assignments appear without a refresh, and a
  // "mark all read" fired from another tab/device stays in sync here.
  useEffect(() => {
    const supabase = createClient();
    const channel = supabase
      .channel("notifications-page")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "notifications" },
        (payload) => {
          if (payload.eventType === "INSERT") {
            const row = payload.new as Notification;
            setNotifications((prev) => {
              if (!prev) return [row];
              if (prev.some((n) => n.id === row.id)) return prev;
              return [row, ...prev];
            });
          } else if (payload.eventType === "UPDATE") {
            const row = payload.new as Notification;
            setNotifications((prev) =>
              prev?.map((n) => (n.id === row.id ? { ...n, ...row } : n)) ??
              prev,
            );
          } else if (payload.eventType === "DELETE") {
            const oldRow = payload.old as Partial<Notification>;
            setNotifications(
              (prev) => prev?.filter((n) => n.id !== oldRow.id) ?? prev,
            );
          }
        },
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, []);

  const markRead = useCallback(
    async (id: string) => {
      // Optimistic — the row is already visually "read" by the time the
      // request lands, so the UI doesn't wait on the round-trip.
      setNotifications(
        (prev) =>
          prev?.map((n) =>
            n.id === id && !n.read_at
              ? { ...n, read_at: new Date().toISOString() }
              : n,
          ) ?? prev,
      );
      const supabase = createClient();
      const { error: updateErr } = await supabase
        .from("notifications")
        .update({ read_at: new Date().toISOString() })
        .eq("id", id)
        .is("read_at", null);
      if (updateErr) {
        toast.error(t("markReadError"));
        load();
      }
    },
    [load, t],
  );

  const handleClick = useCallback(
    (n: Notification) => {
      if (!n.read_at) markRead(n.id);
      if (n.conversation_id) {
        setInboxOpenTarget(n.conversation_id);
        router.push("/inbox");
      }
    },
    [markRead, router],
  );

  const unreadIds = notifications?.filter((n) => !n.read_at).map((n) => n.id) ?? [];

  const markAllRead = useCallback(async () => {
    if (unreadIds.length === 0) return;
    setMarkingAll(true);
    const now = new Date().toISOString();
    setNotifications(
      (prev) => prev?.map((n) => (n.read_at ? n : { ...n, read_at: now })) ?? prev,
    );
    const supabase = createClient();
    const { error: updateErr } = await supabase
      .from("notifications")
      .update({ read_at: now })
      .is("read_at", null);
    setMarkingAll(false);
    if (updateErr) {
      toast.error(t("markAllError"));
      load();
    }
  }, [unreadIds.length, load, t]);

  const deleteOne = useCallback(
    async (id: string) => {
      // Optimistic, like markRead: the row is gone before the request lands.
      setNotifications((prev) => prev?.filter((n) => n.id !== id) ?? prev);
      const supabase = createClient();
      const { error: deleteErr } = await supabase
        .from("notifications")
        .delete()
        .eq("id", id);
      if (deleteErr) {
        toast.error(t("deleteError"));
        load();
      }
    },
    [load, t],
  );

  const deleteAll = useCallback(async () => {
    if (!user) return;
    setDeletingAll(true);
    setNotifications([]);
    const supabase = createClient();
    // RLS already limits a delete to the caller's rows; the filter states it.
    const { error: deleteErr } = await supabase
      .from("notifications")
      .delete()
      .eq("user_id", user.id);
    setDeletingAll(false);
    setConfirmAllOpen(false);
    if (deleteErr) {
      toast.error(t("deleteAllError"));
      load();
      return;
    }
    toast.success(t("deleteAllDone"));
  }, [user, load, t]);

  if (error) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-2">
        <p className="text-sm text-destructive">{error}</p>
        <Button variant="outline" onClick={() => window.location.reload()}>
          {t("retry")}
        </Button>
      </div>
    );
  }

  if (notifications === null) {
    return (
      <div className="flex h-64 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <PageShell>
      <PageHeader
        title={t("title")}
        description={t("description")}
        actions={
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={unreadIds.length === 0 || markingAll}
              onClick={markAllRead}
            >
              {markingAll ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <CheckCheck className="h-4 w-4" />
              )}
              {t("markAllRead")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={notifications.length === 0 || !user}
              onClick={() => setConfirmAllOpen(true)}
            >
              <Trash2 className="h-4 w-4" />
              {t("deleteAll")}
            </Button>
          </div>
        }
      />

      {notifications.length === 0 ? (
        <EmptyState
          icon={Bell}
          title={t("emptyTitle")}
          description={t("emptyDescription")}
        />
      ) : (
        <ul className="space-y-2">
          {notifications.map((n) => {
            const Icon = TYPE_ICON[n.type] ?? Bell;
            const isUnread = !n.read_at;
            return (
              <li key={n.id}>
                <div
                  className={cn(
                    "relative rounded-xl border transition-colors",
                    isUnread
                      ? "border-primary/30 bg-primary/5 hover:border-primary/50"
                      : "border-border bg-card hover:border-border/70",
                  )}
                >
                  {/* Zona clicable: toda la tarjeta, como antes. El botón
                      de acción de promo_etecsa va FUERA de aquí (un botón
                      dentro de otro botón no es HTML válido). */}
                  <button
                    type="button"
                    onClick={() => handleClick(n)}
                    className="flex w-full items-start gap-3 p-4 pr-12 text-left"
                  >
                    <div
                      className={cn(
                        "flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-lg",
                        isUnread ? "bg-primary/15" : "bg-muted",
                      )}
                      aria-hidden
                    >
                      <Icon
                        className={cn(
                          "h-5 w-5",
                          isUnread ? "text-primary" : "text-muted-foreground",
                        )}
                      />
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        <span
                          className={cn(
                            "break-words text-sm font-semibold",
                            isUnread
                              ? "text-foreground"
                              : "text-muted-foreground",
                          )}
                        >
                          {n.title}
                        </span>
                        {n.type === "resumen_diario" && (
                          <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                            {t("digestBadge")}
                          </span>
                        )}
                        {isUnread && (
                          <span
                            aria-label={t("unread")}
                            className="h-2 w-2 flex-shrink-0 rounded-full bg-primary"
                          />
                        )}
                      </div>
                      {n.body && (
                        <p className="mt-1 whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
                          {n.body}
                        </p>
                      )}
                      <p className="mt-1 text-[11px] text-muted-foreground/70">
                        {formatDistanceToNow(new Date(n.created_at), {
                          addSuffix: true,
                        })}
                      </p>
                    </div>
                  </button>
                  {/* Borrar: fuera del botón de la tarjeta (HTML válido) y
                      sin marcar como leída ni navegar. */}
                  <button
                    type="button"
                    aria-label={t("deleteOne")}
                    title={t("deleteOne")}
                    onClick={(e) => {
                      e.stopPropagation();
                      deleteOne(n.id);
                    }}
                    className="absolute right-2 top-2 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                  >
                    <X className="h-4 w-4" aria-hidden />
                  </button>
                  {/* Acción para la promoción Etecsa pendiente. */}
                  {n.type === "promo_etecsa" &&
                    promoChecked &&
                    promoPendiente && (
                      <div className="flex items-center justify-between gap-3 border-t border-border/60 px-4 py-3">
                        <div className="min-w-0">
                          <p className="truncate text-xs font-medium text-foreground">
                            {promoPendiente.resumen}
                          </p>
                          {!promoPendiente.hay_precio && (
                            <p className="mt-0.5 flex items-start gap-1 text-xs font-medium text-destructive">
                              <AlertTriangle className="mt-0.5 h-3.5 w-3.5 flex-shrink-0" />
                              <span>
                                Falta poner el precio en el negocio: confirmar
                                no servirá hasta que esté definido.
                              </span>
                            </p>
                          )}
                        </div>
                        <div className="flex shrink-0 items-center gap-2">
                          <Button
                            size="sm"
                            disabled={promoAction !== null || !promoPendiente.hay_precio}
                            onClick={confirmPromo}
                            title={
                              promoPendiente.hay_precio
                                ? "Permitir que el bot use esta promoción"
                                : "Define primero el precio de esta recarga"
                            }
                          >
                            {promoAction === "confirm" ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              "Confirmar promoción"
                            )}
                          </Button>
                          <Button
                            variant="outline"
                            size="sm"
                            disabled={promoAction !== null}
                            onClick={discardPromo}
                            title="No permitir que el bot use esta promoción"
                          >
                            {promoAction === "discard" ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              <>
                                <XCircle className="mr-1.5 h-4 w-4" />
                                Descartar
                              </>
                            )}
                          </Button>
                        </div>
                      </div>
                    )}
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <Dialog
        open={confirmAllOpen}
        onOpenChange={(open) => !deletingAll && setConfirmAllOpen(open)}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("deleteAllTitle")}</DialogTitle>
            <DialogDescription>{t("deleteAllDescription")}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="ghost"
              onClick={() => setConfirmAllOpen(false)}
              disabled={deletingAll}
            >
              {t("cancel")}
            </Button>
            <Button
              variant="destructive"
              onClick={deleteAll}
              disabled={deletingAll}
            >
              {deletingAll ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              {t("deleteAllConfirm")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </PageShell>
  );
}
