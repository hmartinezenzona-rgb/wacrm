"use client";

import { useEffect, useRef } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Message } from "@/types";

/**
 * Per-conversation realtime channel for the open thread (ADR-5).
 *
 * The account-wide `inbox-realtime` channel keeps listening to message
 * INSERTs only, because the chat sound and the conversation-list preview
 * depend on messages from every conversation. Rows that change AFTER the
 * insert (delivery status, and from slice 6 the media settle) are the noisy
 * traffic at inbox volume, so they are filtered server-side to the one
 * conversation on screen.
 *
 * The channel is torn down on conversation change and unmount, exactly like
 * the `reactions:<id>` channel in the thread.
 */
export function useThreadRealtime(
  conversationId: string | null | undefined,
  onUpdate: (message: Message) => void,
) {
  const onUpdateRef = useRef(onUpdate);
  useEffect(() => {
    onUpdateRef.current = onUpdate;
  });

  useEffect(() => {
    if (!conversationId) return;

    const supabase = createClient();
    const channel = supabase
      .channel(`thread:${conversationId}`)
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "messages",
          filter: `conversation_id=eq.${conversationId}`,
        },
        (payload) => {
          onUpdateRef.current(payload.new as Message);
        },
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [conversationId]);
}
