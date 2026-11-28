// ============================================================
// The bot-facing tail of inbound processing.
//
// Extracted verbatim from the webhook route in slice 6a so the order can
// change in one place: since insert-first ingest, this runs only AFTER the
// message's media settled, because a flow/automation step may forward the
// image and must find a settled row (`ready` or `failed`), never
// `pending`.
//
// Nothing here was rewritten: the calls, their order and their comments are
// the ones the route had inline.
// ============================================================

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { runAutomationsForTrigger } from '@/lib/automations/engine';
import { dispatchInboundToAiReply } from '@/lib/ai/auto-reply';
import { dispatchInboundToFlows } from '@/lib/flows/engine';
import { dispatchEventDurably } from '@/lib/webhooks/outbox';

/** The parts of an inbound WhatsApp message the tail reads. */
export interface InboundTailMessage {
  id: string;
  type: string;
  text?: { body?: string };
}

export interface RunInboundTailArgs {
  accountId: string;
  configOwnerUserId: string;
  contactId: string;
  conversationId: string;
  message: InboundTailMessage;
  contentType: string;
  contentText: string | null;
  interactiveReplyId: string | null;
  isFirstInboundMessage: boolean;
  contactWasCreated: boolean;
}

export async function runInboundTail(args: RunInboundTailArgs): Promise<void> {
  const {
    accountId,
    configOwnerUserId,
    contactId,
    conversationId,
    message,
    contentType,
    contentText,
    interactiveReplyId,
    isFirstInboundMessage,
    contactWasCreated,
  } = args;

  const flowResult = await dispatchInboundToFlows({
    accountId,
    userId: configOwnerUserId,
    contactId: contactId,
    conversationId: conversationId,
    message:
      interactiveReplyId
        ? {
            kind: 'interactive_reply',
            reply_id: interactiveReplyId,
            reply_title: contentText ?? '',
            meta_message_id: message.id,
          }
        : {
            kind: 'text',
            text: contentText ?? message.text?.body ?? '',
            meta_message_id: message.id,
          },
    isFirstInboundMessage,
  })
  const flowConsumed = flowResult.consumed

  // Fire any automations that react to this webhook event. All dispatches
  // run here (not earlier) so the contact, conversation, and inbound
  // message all exist before any step — including send_message — runs.
  // Fire-and-forget: a slow or failing automation must not block the
  // webhook's 200 OK response to Meta.
  const inboundText = contentText ?? message.text?.body ?? ''
  const automationTriggers: (
    | 'new_contact_created'
    | 'first_inbound_message'
    | 'new_message_received'
    | 'keyword_match'
    | 'interactive_reply'
  )[] = []
  // Content-level triggers are suppressed when a flow consumed the
  // message — see the comment block above.
  if (!flowConsumed) {
    automationTriggers.push('new_message_received', 'keyword_match')
    // Interactive tap → fire the interactive_reply trigger too (only
    // meaningful when a button/list reply actually arrived). Enables
    // automation-only chained menus; when a Flow owns the menu it will
    // have consumed the reply and this is skipped.
    if (interactiveReplyId) {
      automationTriggers.push('interactive_reply')
    }
  }
  // new_contact_created fires only when the webhook just auto-created the
  // contact row. first_inbound_message fires whenever this is the contact's
  // first-ever customer-sent message — a superset that also catches
  // manually-imported contacts sending for the first time. We dispatch both
  // so users can pick whichever semantic they want; an automation that
  // listens to only one trigger runs only when that trigger matches.
  if (contactWasCreated) automationTriggers.unshift('new_contact_created')
  if (isFirstInboundMessage) automationTriggers.unshift('first_inbound_message')
  for (const triggerType of automationTriggers) {
    runAutomationsForTrigger({
      accountId,
      triggerType,
      contactId: contactId,
      context: {
        message_text: inboundText,
        conversation_id: conversationId,
        // Only set on interactive taps; drives the interactive_reply
        // trigger's exact-id match.
        interactive_reply_id: interactiveReplyId ?? undefined,
      },
    }).catch((err) => console.error('[automations] dispatch failed:', err))
  }

  // AI auto-reply. Runs only for plain-text inbound the deterministic
  // flow runner did NOT consume (flows win over the LLM), and only when
  // the account has enabled it. Awaited inside `after()` (same reason as
  // the webhook dispatch below); `dispatchInboundToAiReply` owns its
  // eligibility gates + try/catch and never throws.
  if (!flowConsumed && !interactiveReplyId && inboundText.trim()) {
    await dispatchInboundToAiReply({
      accountId,
      conversationId: conversationId,
      contactId: contactId,
      configOwnerUserId,
    })
  }

  // message.received webhook (public API). Awaited — not fire-and-forget
  // — because we're inside the route's `after()` block, which only keeps
  // the function alive for promises it can see; a detached promise could
  // be frozen before it delivers. Durable for message.received (migration
  // 301): the event is stored before the attempt, a failure stays pending
  // for the cron worker, and a retry skips a wamid the Cerebro already saw.
  // (conversation.created is emitted earlier, right after the thread is
  // opened.)
  await dispatchEventDurably(supabaseAdmin(), accountId, 'message.received', {
    conversation_id: conversationId,
    contact_id: contactId,
    whatsapp_message_id: message.id,
    content_type: contentType,
    text: contentText,
  })

}
