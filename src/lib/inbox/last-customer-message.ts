import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * When the customer last wrote in a conversation, or `null` if they
 * never did (or the lookup failed).
 *
 * The pipelines board needs the 24-hour window for a deal whose thread
 * it has not loaded — the inbox derives it from messages already in
 * memory, but the board only has a `conversation_id`. One indexed row
 * is cheaper than pulling a thread it will never render.
 *
 * A failed query returns `null`, which reads as "window closed". That
 * is the safe direction: the operator is offered the deliver-without-
 * proof path instead of being handed a send that Meta would reject.
 */
export async function fetchLastCustomerMessageAt(
  supabase: SupabaseClient,
  conversationId: string,
): Promise<string | null> {
  const { data, error } = await supabase
    .from("messages")
    .select("created_at")
    .eq("conversation_id", conversationId)
    .eq("sender_type", "customer")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error || !data) return null;
  return (data as { created_at: string }).created_at;
}
