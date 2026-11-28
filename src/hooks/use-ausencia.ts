"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";

/** Active absence as returned by /api/ausencia. */
export interface Ausencia {
  motivo: string;
  /** UTC ISO instant the team is back. */
  hasta: string;
  /** Spanish, ready to render: "a las 3:00 pm", "mañana a las 9:00 am". */
  hasta_texto: string;
  por: string;
}

const ENDPOINT = "/api/ausencia";
const POLL_MS = 60_000;
/** setTimeout overflows past 2^31-1 ms; a re-check every poll is enough anyway. */
const MAX_TIMER_MS = 2_147_483_647;

function isActive(ausencia: Ausencia | null): ausencia is Ausencia {
  if (!ausencia) return false;
  const until = Date.parse(ausencia.hasta);
  return Number.isFinite(until) && Date.now() < until;
}

/**
 * Shared away-mode state: loads on mount, on window focus and every minute,
 * and hides the absence locally the moment `hasta` passes (no fetch needed).
 * Mount it once (see AwayModeProvider) so there is a single poller.
 */
export function useAusencia() {
  const t = useTranslations("AwayMode");
  const [raw, setRaw] = useState<Ausencia | null>(null);
  const [loading, setLoading] = useState(true);
  // Bumped by the expiry timer to force a re-render once `hasta` passes.
  const [, setTick] = useState(0);
  const tRef = useRef(t);
  tRef.current = t;

  const refresh = useCallback(async () => {
    try {
      const response = await fetch(ENDPOINT, { cache: "no-store" });
      const payload = (await response.json().catch(() => null)) as {
        ausencia?: Ausencia | null;
        error?: string;
      } | null;
      if (!response.ok) throw new Error(payload?.error || "load failed");
      setRaw(payload?.ausencia ?? null);
    } catch (err) {
      console.warn("[ausencia] load:", err instanceof Error ? err.message : err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const interval = setInterval(() => void refresh(), POLL_MS);
    const onFocus = () => void refresh();
    window.addEventListener("focus", onFocus);
    return () => {
      clearInterval(interval);
      window.removeEventListener("focus", onFocus);
    };
  }, [refresh]);

  useEffect(() => {
    if (!raw) return;
    const until = Date.parse(raw.hasta);
    if (!Number.isFinite(until)) return;
    const wait = Math.min(Math.max(until - Date.now(), 0), MAX_TIMER_MS);
    const timer = setTimeout(() => setTick((n) => n + 1), wait);
    return () => clearTimeout(timer);
  }, [raw]);

  const send = useCallback(
    async (init: RequestInit, failure: "save" | "clear"): Promise<boolean> => {
      try {
        const response = await fetch(ENDPOINT, init);
        const payload = (await response.json().catch(() => null)) as {
          ausencia?: Ausencia | null;
          error?: string;
        } | null;
        if (!response.ok) {
          toast.error(
            response.status === 400 && payload?.error
              ? payload.error
              : tRef.current(`errors.${failure}`),
          );
          return false;
        }
        setRaw(payload?.ausencia ?? null);
        return true;
      } catch (err) {
        console.error(`[ausencia] ${failure}:`, err instanceof Error ? err.message : err);
        toast.error(tRef.current(`errors.${failure}`));
        return false;
      }
    },
    [],
  );

  const set = useCallback(
    (hasta: Date, motivo: string) =>
      send(
        {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ hasta: hasta.toISOString(), motivo }),
        },
        "save",
      ),
    [send],
  );

  const clear = useCallback(() => send({ method: "DELETE" }, "clear"), [send]);

  const ausencia = isActive(raw) ? raw : null;
  return { ausencia, loading, set, clear, refresh };
}
