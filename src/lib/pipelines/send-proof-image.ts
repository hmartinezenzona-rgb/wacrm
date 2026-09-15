// ============================================================
// Sending a delivery proof image through `/api/whatsapp/send`.
//
// Extracted from the pipelines board's `runDelivery` (panel-22) so the
// request shape and the `db_error` + wamid → sent-not-recorded mapping
// can be unit-tested without a browser. Behaviour is UNCHANGED from the
// inline version: in particular, a thrown fetch is not caught here — it
// propagates to `deliverDeal`, which is what turns it into "unconfirmed"
// (the customer might have gotten it; nothing here can tell).
// ============================================================

import type {
  SendProofArgs,
  SendProofOutcome,
} from "@/lib/pipelines/deliver-with-proof";

export async function sendProofImage({
  conversationId,
  mediaUrl,
  caption,
}: SendProofArgs): Promise<SendProofOutcome> {
  const res = await fetch("/api/whatsapp/send", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      conversation_id: conversationId,
      message_type: "image",
      media_url: mediaUrl,
      content_text: caption || undefined,
    }),
  });
  const body = await res.json().catch(() => ({}));

  if (res.ok) {
    return { ok: true, wamid: body?.whatsapp_message_id };
  }

  const message = body?.error || `HTTP ${res.status}`;
  // `db_error` with a wamid means Meta ACCEPTED the image and WaCRM then
  // failed to save the row. An HTTP error that is really a delivered
  // message — the one case where "it failed, try again" would send the
  // customer a duplicate.
  if (body?.code === "db_error" && body?.whatsapp_message_id) {
    return {
      ok: false,
      outcome: "sent-not-recorded",
      message,
      wamid: body.whatsapp_message_id as string,
    };
  }
  return { ok: false, outcome: "not-sent", message };
}
