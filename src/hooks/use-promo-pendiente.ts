"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";

/** Row returned by the authenticated ETECSA promotions route. */
export interface PromoPendiente {
  id: string;
  min_cup: number;
  max_cup: number | null;
  multiplicador: number | null;
  precio_gyd: number | null;
  vigente_desde: string;
  vigente_hasta: string;
  /** Text already formatted to render as is. */
  resumen: string;
  /** When false, confirming is useless: the business has no price yet. */
  hay_precio: boolean;
}

export type PromoAction = "confirm" | "discard";

const ENDPOINT = "/api/promotions/etecsa";

/**
 * Shared state for the pending ETECSA promo: loads it, refetches when a
 * promo_etecsa notification arrives (re-dispatched by useUnreadNotifications
 * as a window event, so no extra realtime channel is opened), and runs
 * confirm/discard.
 */
export function usePromoPendiente() {
  const [promo, setPromo] = useState<PromoPendiente | null>(null);
  // Tells "loaded, none pending" apart from "still loading" (no flicker).
  const [checked, setChecked] = useState(false);
  const [action, setAction] = useState<PromoAction | null>(null);
  const busy = useRef(false);

  const reload = useCallback(async () => {
    try {
      const response = await fetch(ENDPOINT, { cache: "no-store" });
      const payload = (await response.json().catch(() => null)) as {
        promo?: PromoPendiente | null;
        error?: string;
      } | null;
      if (!response.ok) {
        throw new Error(payload?.error || "No se pudo cargar la promoción");
      }
      setPromo(payload?.promo ?? null);
    } catch (err) {
      console.warn(
        "[promo-pendiente] load:",
        err instanceof Error ? err.message : err,
      );
    } finally {
      setChecked(true);
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  useEffect(() => {
    const onInsert = (event: Event) => {
      const row = (event as CustomEvent<{ type?: string } | null>).detail;
      if (row?.type === "promo_etecsa") void reload();
    };
    window.addEventListener("wacrm:notification-insert", onInsert);
    return () =>
      window.removeEventListener("wacrm:notification-insert", onInsert);
  }, [reload]);

  const run = useCallback(
    async (kind: PromoAction) => {
      if (busy.current || !promo) return;
      busy.current = true;
      setAction(kind);
      try {
        const response = await fetch(ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: kind, id: promo.id }),
        });
        const payload = (await response.json().catch(() => null)) as {
          result?: "confirmada" | "descartada";
          promo?: PromoPendiente | null;
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
        if (payload && "promo" in payload) {
          setPromo(payload.promo ?? null);
        } else {
          await reload();
        }
      } catch (err) {
        console.error(
          `[promo-pendiente] ${kind}:`,
          err instanceof Error ? err.message : err,
        );
        toast.error(
          kind === "confirm"
            ? "No se pudo confirmar la promoción"
            : "No se pudo descartar la promoción",
        );
      } finally {
        busy.current = false;
        setAction(null);
      }
    },
    [promo, reload],
  );

  const confirm = useCallback(() => void run("confirm"), [run]);
  const discard = useCallback(() => void run("discard"), [run]);

  return { promo, checked, action, confirm, discard, reload };
}
