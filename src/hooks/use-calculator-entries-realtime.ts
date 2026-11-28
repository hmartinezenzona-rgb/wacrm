"use client";

import { useEffect, useRef } from "react";
import { createClient } from "@/lib/supabase/client";
import type {
  CalculatorEntryRealtimeEventType,
  CalculatorEntryRealtimeRow,
} from "@/lib/calculator/realtime-entry";

export interface CalculatorEntryRealtimeEvent {
  eventType: CalculatorEntryRealtimeEventType;
  new: CalculatorEntryRealtimeRow;
  old: Partial<CalculatorEntryRealtimeRow>;
}

interface UseCalculatorEntriesRealtimeOptions {
  onEntryEvent: (event: CalculatorEntryRealtimeEvent) => void;
  enabled?: boolean;
}

/**
 * Live `remittance_calculator_entries` feed for the calculadora page (B4.2
 * — "the calculator updates in real time when a remesa completes, with no
 * page refresh"). Same shape as `use-realtime.ts`'s messages/conversations
 * subscription: an unfiltered `postgres_changes` channel, callback stashed
 * in a ref so a parent re-render never forces a resubscribe, cleaned up on
 * unmount.
 *
 * Unfiltered on purpose — `remittance_calculator_entries_select`
 * (migration 106, `is_account_member(account_id)`) already scopes which
 * rows this session can see, the same policy the page's own
 * `GET /api/calculadora` read relies on, so no client-side account filter
 * is needed here either. Requires the table in the `supabase_realtime`
 * publication (migration 145) — without it, no event for this table ever
 * reaches any subscriber, filtered or not.
 */
export function useCalculatorEntriesRealtime({
  onEntryEvent,
  enabled = true,
}: UseCalculatorEntriesRealtimeOptions) {
  const onEntryRef = useRef(onEntryEvent);
  useEffect(() => {
    onEntryRef.current = onEntryEvent;
  });

  useEffect(() => {
    if (!enabled) return;

    const supabase = createClient();
    const channel = supabase
      .channel("calculadora-calculator-entries")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "remittance_calculator_entries" },
        (payload) => {
          onEntryRef.current({
            eventType: payload.eventType as CalculatorEntryRealtimeEventType,
            new: payload.new as CalculatorEntryRealtimeRow,
            old: payload.old as Partial<CalculatorEntryRealtimeRow>,
          });
        },
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [enabled]);
}
