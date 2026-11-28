"use client";

import { useCallback, useEffect, useRef } from "react";

// Reuses the existing "incidencia" chime — this repo ships no
// chat-message-specific sound asset yet (public/sounds/ only has
// incidencia.mp3 / incidencia-v2.mp3). Low-stakes default for B1.5,
// swap this constant if a dedicated asset is added later.
const SOUND_URL = "/sounds/incidencia-v2.mp3";

/**
 * Plays / stops a WhatsApp-like notification chime for incoming chat
 * messages in the inbox (B1.5a). Mirrors the unlock-on-gesture pattern
 * from `useNotificationAlerts`: browsers block audio playback until a
 * user gesture, so the element is silently "warmed up" on the first
 * pointerdown.
 *
 * THIS HOOK MUST NEVER THROW — same rule as `useNotificationAlerts`,
 * since it's driven from realtime message events on the inbox page; an
 * exception here must never break the inbox itself.
 */
export function useChatMessageSound() {
  const audioRef = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    try {
      const audio = new Audio(SOUND_URL);
      audio.preload = "auto";
      audioRef.current = audio;
    } catch {
      audioRef.current = null;
    }

    const onFirstGesture = () => {
      try {
        const audio = audioRef.current;
        if (!audio) return;
        audio.muted = true;
        void audio
          .play()
          .then(() => {
            try {
              audio.pause();
              audio.currentTime = 0;
            } finally {
              audio.muted = false;
            }
          })
          .catch(() => {
            audio.muted = false;
          });
      } catch {
        /* noop */
      }
    };
    window.addEventListener("pointerdown", onFirstGesture, { once: true });

    return () => {
      try {
        window.removeEventListener("pointerdown", onFirstGesture);
        audioRef.current?.pause();
      } catch {
        /* noop */
      }
    };
  }, []);

  const play = useCallback(() => {
    try {
      const audio = audioRef.current;
      if (!audio) return;
      audio.currentTime = 0;
      void audio.play().catch(() => {
        /* blocked/unavailable — the message itself still shows */
      });
    } catch {
      /* noop */
    }
  }, []);

  const stop = useCallback(() => {
    try {
      const audio = audioRef.current;
      if (!audio) return;
      audio.pause();
      audio.currentTime = 0;
    } catch {
      /* noop */
    }
  }, []);

  return { play, stop };
}
