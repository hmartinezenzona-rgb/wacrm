"use client";

import { useEffect } from "react";
import type { Notification } from "@/types";

// v2: mismo tono, nivel corregido (el v1 era casi inaudible). Nombre
// nuevo a propósito: /sounds/* se sirve con caché (s-maxage + SWR), y
// con el mismo nombre el borde podía seguir sirviendo el viejo.
const SOUND_URL = "/sounds/incidencia-v2.mp3";

/**
 * Alerts when a notification row is inserted: plays a sound and shows a
 * desktop notification. Used for deal_incidencia / mensaje_fallido so an
 * incident is heard even with the tab in the background.
 *
 * Mounted ONCE in dashboard-shell (which wraps every dashboard page).
 *
 * Rules:
 * - RLS on `notifications` scopes inserts to the current user, same as
 *   the unread-count hook; no explicit filter needed.
 * - THIS HOOK MUST NEVER THROW. The shell wraps every page, so an
 *   exception here would take down the whole CRM. If the alert fails,
 *   only the alert fails.
 * - The browser blocks audio until a user gesture, and Notification
 *   permission must be requested from a gesture too — both are handled
 *   on the first pointerdown.
 */
export function useNotificationAlerts() {
  useEffect(() => {
    // Outer guard: nothing in here may propagate.
    try {
      let audio: HTMLAudioElement | null = null;
      try {
        audio = new Audio(SOUND_URL);
        audio.preload = "auto";
      } catch {
        audio = null;
      }

      // Unlock audio on the first user gesture (autoplay policy). Also
      // ask for notification permission from that same gesture.
      const onFirstGesture = () => {
        try {
          if (audio) {
            void audio
              .play()
              .then(() => {
                try {
                  audio?.pause();
                } catch {
                  /* noop */
                }
              })
              .catch(() => {
                /* blocked — sound stays muted, fine */
              });
          }
          if (
            typeof Notification !== "undefined" &&
            Notification.permission === "default"
          ) {
            void Notification.requestPermission().catch(() => {
              /* user said no — fine */
            });
          }
        } catch {
          /* noop */
        }
      };
      window.addEventListener("pointerdown", onFirstGesture, { once: true });

      const playSound = () => {
        try {
          if (!audio) return;
          audio.currentTime = 0;
          void audio.play().catch(() => {
            /* blocked/unavailable — sound only */
          });
        } catch {
          /* noop */
        }
      };

      const showDesktopNotification = (row: Notification) => {
        try {
          if (
            typeof Notification === "undefined" ||
            Notification.permission !== "granted"
          ) {
            return;
          }
          const n = new Notification(row.title, {
            body: row.body ?? undefined,
          });
          n.onclick = () => {
            try {
              window.focus();
              window.location.href = row.conversation_id
                ? `/inbox?conversation=${row.conversation_id}`
                : "/notifications";
              n.close();
            } catch {
              /* noop */
            }
          };
        } catch {
          /* noop */
        }
      };

      // No abre canal de realtime: el INSERT ya lo recibe el contador
      // (use-unread-notifications) y lo anuncia con este evento. Dos
      // canales sobre la misma tabla = solo uno recibe, el otro calla
      // sin error — por eso este hook solo escucha.
      const onNotification = (e: Event) => {
        try {
          const row = (e as CustomEvent<Notification>).detail;
          playSound();
          showDesktopNotification(row);
        } catch {
          /* never throw from the event callback */
        }
      };
      window.addEventListener("wacrm:notification-insert", onNotification);

      return () => {
        try {
          window.removeEventListener("pointerdown", onFirstGesture);
          window.removeEventListener(
            "wacrm:notification-insert",
            onNotification,
          );
        } catch {
          /* noop */
        }
      };
    } catch {
      return undefined;
    }
  }, []);
}
