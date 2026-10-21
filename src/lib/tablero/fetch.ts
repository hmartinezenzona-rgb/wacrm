import type { SupabaseClient } from "@supabase/supabase-js";
import type { BoardOperation } from "./board";

export class BoardFetchError extends Error {
  constructor(
    public readonly kind: "forbidden" | "failed",
    message: string,
  ) {
    super(message);
    this.name = "BoardFetchError";
  }
}

interface BoardRow {
  operation_id: string;
  conversation_id: string;
  contact_name: string | null;
  contact_phone: string | null;
  service_type: string;
  delivery_method: string | null;
  status: string;
  quoted_source_amount: number | string | null;
  source_currency: string | null;
  created_at: string;
  completed_at: string | null;
  state_since: string;
  beneficiaries_complete: boolean | null;
  // Added by migration 258; absent (or null) while the RPC is still the previous one.
  beneficiary_types?: string[] | null;
  quoted_destination_amount?: number | string | null;
  destination_currency?: string | null;
  recipient_label?: string | null;
  recipient_count?: number | null;
  mixed_group_id?: string | null;
}

/** Reads the board with the CALLER's session client (never service role): the
 *  RPC itself resolves the account and refuses non-members with 42501. */
export async function fetchBoard(supabase: Pick<SupabaseClient, "rpc">): Promise<BoardOperation[]> {
  const { data, error } = await supabase.rpc("crm_tablero_operaciones");
  if (error) {
    throw new BoardFetchError(error.code === "42501" ? "forbidden" : "failed", error.message);
  }
  return ((data ?? []) as BoardRow[]).map((r) => ({
    operationId: r.operation_id,
    conversationId: r.conversation_id,
    contactName: r.contact_name,
    contactPhone: r.contact_phone,
    serviceType: r.service_type,
    deliveryMethod: r.delivery_method,
    status: r.status,
    quotedSourceAmount: r.quoted_source_amount === null ? null : Number(r.quoted_source_amount),
    sourceCurrency: r.source_currency,
    createdAt: r.created_at,
    completedAt: r.completed_at,
    stateSince: r.state_since,
    beneficiariesComplete: r.beneficiaries_complete,
    beneficiaryTypes: r.beneficiary_types ?? [],
    quotedDestinationAmount: r.quoted_destination_amount == null ? null : Number(r.quoted_destination_amount),
    destinationCurrency: r.destination_currency ?? null,
    recipientLabel: r.recipient_label ?? null,
    recipientCount: r.recipient_count ?? 0,
    mixedGroupId: r.mixed_group_id ?? null,
  }));
}
