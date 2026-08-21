"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import type { Notification } from "@/types";
import {
  AlertTriangle,
  Bell,
  CheckCheck,
  Loader2,
  MessageSquareX,
  Percent,
  XCircle,
  UserPlus,
} from "lucide-react";
import { formatDistanceToNow } from "date-fns";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { toast } from "sonner";

// Icon per notification type. Only one type existed at first
// (conversation_assigned) but this keeps future types a one-line add.
const TYPE_ICON: Record<Notification["type"], typeof Bell> = {
  conversation_assigned: UserPlus,
  deal_incidencia: AlertTriangle,
  mensaje_fallido: MessageSquareX,
  promo_etecsa: Percent,
};

/** Fila de la ruta autenticada de promociones Etecsa. */
interface PromoPendiente {
  id: string;
  min_cup: number;
  max_cup: number | null;
  multiplicador: number | null;
  precio_gyd: number | null;
  vigente_desde: string;
  vigente_hasta: string;
  /** Texto ya formateado para pintar tal cual. */
  resumen: string;
  /** Si false, confirmar no sirve: falta poner precio al negocio. */
  hay_precio: boolean;
}

export default function NotificationsPage() {
  const router = useRouter();
  const { accountId } = useAuth();
  const [notifications, setNotifications] = useState<Notification[] | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);
  const [markingAll, setMarkingAll] = useState(false);
  const [promoPendiente, setPromoPendiente] = useState<PromoPendiente | null>(
    null,
  );
  // Distingue "ya cargó y no hay" de "aún cargando" (evita parpadeos).
  const [promoChecked, setPromoChecked] = useState(false);
  const [promoAction, setPromoAction] = useState<"confirm" | "discard" | null>(
    null,
  );

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

  // Promoción Etecsa pendiente de decidir (si la hay). La ruta autentica
  // la sesión y usa el cliente de servidor, con fallback para instalaciones
  // donde el grant/RPC de PostgREST aún no se haya refrescado.
  const loadPromoPendiente = useCallback(async () => {
    try {
      const response = await fetch("/api/promotions/etecsa", {
        cache: "no-store",
      });
      const payload = (await response.json().catch(() => null)) as {
        promo?: PromoPendiente | null;
        error?: string;
      } | null;
      if (!response.ok) {
        throw new Error(payload?.error || "No se pudo cargar la promoción");
      }
      setPromoPendiente(payload?.promo ?? null);
    } catch (err) {
      console.warn(
        "[notifications] promo pendiente:",
        err instanceof Error ? err.message : err,
      );
    } finally {
      setPromoChecked(true);
    }
  }, []);

  useEffect(() => {
    void loadPromoPendiente();
  }, [loadPromoPendiente]);

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
            // Entró una promo nueva: recargar la RPC para que la franja
            // del botón aparezca sin recargar la página (el caso real:
            // el operador tiene el CRM abierto todo el día).
            if (row.type === "promo_etecsa") {
              void loadPromoPendiente();
            }
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
  }, [loadPromoPendiente]);

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
        toast.error("Failed to mark notification as read");
        load();
      }
    },
    [load],
  );

  const handleClick = useCallback(
    (n: Notification) => {
      if (!n.read_at) markRead(n.id);
      if (n.conversation_id) {
        router.push(`/inbox?c=${n.conversation_id}`);
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
      toast.error("Failed to mark all as read");
      load();
    }
  }, [unreadIds.length, load]);

  const runPromoAction = useCallback(
    async (action: "confirm" | "discard") => {
      if (promoAction || !promoPendiente) return;
      setPromoAction(action);
      try {
        const response = await fetch("/api/promotions/etecsa", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action, id: promoPendiente.id }),
        });
        const payload = (await response.json().catch(() => null)) as {
          result?: "confirmada" | "descartada";
          error?: string;
        } | null;
        if (!response.ok) {
          throw new Error(payload?.error || "No se pudo actualizar la promoción");
        }
        toast.success(
          payload?.result === "confirmada"
            ? "Promoción confirmada para el bot"
            : "Promoción descartada; el bot no la usará",
        );
        await loadPromoPendiente();
      } catch (err) {
        console.error(
          `[notifications] ${action} promo:`,
          err instanceof Error ? err.message : err,
        );
        toast.error(
          action === "confirm"
            ? "No se pudo confirmar la promoción"
            : "No se pudo descartar la promoción",
        );
      } finally {
        setPromoAction(null);
      }
    },
    [loadPromoPendiente, promoAction, promoPendiente],
  );

  const confirmPromo = useCallback(() => {
    void runPromoAction("confirm");
  }, [runPromoAction]);

  const discardPromo = useCallback(() => {
    void runPromoAction("discard");
  }, [runPromoAction]);

  if (error) {
    return (
      <div className="flex h-64 flex-col items-center justify-center gap-2">
        <p className="text-sm text-destructive">{error}</p>
        <Button variant="outline" onClick={() => window.location.reload()}>
          Retry
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
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Notifications</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Conversations other teammates assign to you show up here.
          </p>
        </div>
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
          Mark all as read
        </Button>
      </div>

      {notifications.length === 0 ? (
        <div className="flex h-48 flex-col items-center justify-center rounded-xl border border-dashed border-border bg-muted/40">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-primary/10">
            <Bell className="h-6 w-6 text-primary" />
          </div>
          <p className="mt-3 text-sm font-medium text-foreground">
            No notifications yet
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            You&apos;ll see an alert here when someone assigns you a
            conversation.
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {notifications.map((n) => {
            const Icon = TYPE_ICON[n.type] ?? Bell;
            const isUnread = !n.read_at;
            return (
              <li key={n.id}>
                <div
                  className={cn(
                    "rounded-xl border transition-colors",
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
                    className="flex w-full items-start gap-3 p-4 text-left"
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
                        {isUnread && (
                          <span
                            aria-label="Unread"
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
    </div>
  );
}
