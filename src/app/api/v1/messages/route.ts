// ============================================================
// POST /api/v1/messages — send a WhatsApp message via the public API.
//
// The headline public endpoint (issue #245). Unlike the dashboard's
// `/api/whatsapp/send` (which takes an internal `conversation_id`),
// this takes a phone number — what an external automation actually
// has — resolves-or-creates the contact + conversation, then runs the
// same shared send core.
//
// Auth: API key with the `messages:send` scope. Account context (and
// the service-role client) come from `requireApiKey`.
//
// Body:
//   {
//     "to": "+14155550123",                 // required, E.164
//     "type": "text",                        // text|template|image|video|document|audio (default: text)
//     "text": "Hello!",                      // text body, or media caption
//     "media_url": "https://…/file.pdf",     // required for image/video/document/audio
//     "filename": "invoice.pdf",             // optional, document filename
//     "template": {                          // required when type=template
//       "name": "order_update",
//       "language": "en_US",
//       "params": ["A123"] | { "body": [...] }   // array = positional body; object = structured
//     },
//     "reply_to_message_id": "<uuid>",       // optional, must be in the same conversation
//     "name": "Jane Doe"                     // optional, names a newly-created contact
//   }
//
// Response (201):
//   { "data": { "message_id", "whatsapp_message_id", "conversation_id",
//               "contact_id", "contact_created" } }
// ============================================================

import { requireApiKey } from '@/lib/auth/api-context';
import { ok, fail, toApiErrorResponse } from '@/lib/api/v1/respond';
import { resolveConversationByPhone } from '@/lib/whatsapp/resolve-conversation';
import {
  sendMessageToConversation,
  validateSendMessageParams,
  SendMessageError,
} from '@/lib/whatsapp/send-message';
import type { InteractiveMessagePayload } from '@/lib/whatsapp/interactive';
import { prepararRespuestaBot } from '@/lib/whatsapp/formato-bot';

// Cuentas cuyo bot externo (n8n) manda texto de un modelo de lenguaje: se
// le da formato de WhatsApp, se parte en burbujas y se agregan botones.
// Otra cuenta lo pide con "formato": "bot"; "formato": "tal_cual" lo apaga.
const CUENTAS_FORMATO_BOT = new Set(['39beb051-96d0-4ee8-9d2f-f26a7ab4d9a7']);
const PAUSA_ENTRE_BURBUJAS_MS = 700;

export async function POST(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'messages:send');

    const body = (await request.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (!body || typeof body !== 'object') {
      return fail('bad_request', 'Request body must be a JSON object', 400);
    }

    const to = typeof body.to === 'string' ? body.to.trim() : '';
    if (!to) {
      return fail('bad_request', "'to' is required", 400);
    }

    const type = typeof body.type === 'string' ? body.type : 'text';

    // Unpack the optional `template` object into the flat params the
    // send core expects. `params` as an array → legacy positional body
    // params; as an object → structured header/body/button params.
    const template =
      body.template && typeof body.template === 'object'
        ? (body.template as Record<string, unknown>)
        : null;
    const templateParams = Array.isArray(template?.params)
      ? (template.params as unknown[]).filter(
          (p): p is string => typeof p === 'string'
        )
      : undefined;
    const templateMessageParams =
      template?.params && !Array.isArray(template.params)
        ? template.params
        : undefined;

    // Validate the message shape BEFORE resolveConversationByPhone
    // finds-or-creates a contact + conversation, so a bad payload 400s
    // without leaving an orphan contact/conversation behind.
    // Validated by `validateSendMessageParams` below; the cast just bridges
    // the untyped JSON body to the send-core param type.
    const interactivePayload =
      body.interactive_payload && typeof body.interactive_payload === 'object'
        ? (body.interactive_payload as InteractiveMessagePayload)
        : null;

    validateSendMessageParams({
      messageType: type,
      contentText: typeof body.text === 'string' ? body.text : null,
      mediaUrl: typeof body.media_url === 'string' ? body.media_url : null,
      templateName: typeof template?.name === 'string' ? template.name : null,
      interactivePayload,
    });

    // Find-or-create the conversation for this phone, then send. Both
    // steps share `SendMessageError`, so one catch maps the whole
    // pipeline to the envelope.
    const resolved = await resolveConversationByPhone(
      ctx.supabase,
      ctx.accountId,
      to,
      typeof body.name === 'string' ? body.name : null
    );

    const formato = typeof body.formato === 'string' ? body.formato : '';
    const darFormato =
      type === 'text' &&
      typeof body.text === 'string' &&
      formato !== 'tal_cual' &&
      (formato === 'bot' || CUENTAS_FORMATO_BOT.has(ctx.accountId));

    if (darFormato) {
      const piezas = prepararRespuestaBot(body.text as string);
      if (piezas.length === 0) {
        return fail('bad_request', "'text' is empty", 400);
      }
      const ids: string[] = [];
      let ultimo: { messageId: string; whatsappMessageId: string | null } | null = null;
      for (const [i, pieza] of piezas.entries()) {
        if (i > 0) await new Promise((r) => setTimeout(r, PAUSA_ENTRE_BURBUJAS_MS));
        const r = await sendMessageToConversation(ctx.supabase, ctx.accountId, {
          conversationId: resolved.conversationId,
          messageType: pieza.tipo === 'texto' ? 'text' : 'interactive',
          contentText: pieza.tipo === 'texto' ? pieza.texto : pieza.payload.body,
          mediaUrl: null,
          filename: null,
          templateName: null,
          templateLanguage: null,
          interactivePayload: pieza.tipo === 'botones' ? pieza.payload : null,
          replyToMessageId:
            i === 0 && typeof body.reply_to_message_id === 'string'
              ? body.reply_to_message_id
              : null,
          aiGenerated: true,
        });
        ids.push(r.messageId);
        ultimo = { messageId: r.messageId, whatsappMessageId: r.whatsappMessageId ?? null };
      }
      return ok(
        {
          message_id: ultimo!.messageId,
          whatsapp_message_id: ultimo!.whatsappMessageId,
          message_ids: ids,
          conversation_id: resolved.conversationId,
          contact_id: resolved.contactId,
          contact_created: resolved.contactCreated,
        },
        201
      );
    }

    const result = await sendMessageToConversation(
      ctx.supabase,
      ctx.accountId,
      {
        conversationId: resolved.conversationId,
        messageType: type,
        contentText: typeof body.text === 'string' ? body.text : null,
        mediaUrl: typeof body.media_url === 'string' ? body.media_url : null,
        filename: typeof body.filename === 'string' ? body.filename : null,
        templateName: typeof template?.name === 'string' ? template.name : null,
        templateLanguage:
          typeof template?.language === 'string' ? template.language : null,
        templateParams,
        templateMessageParams,
        interactivePayload,
        replyToMessageId:
          typeof body.reply_to_message_id === 'string'
            ? body.reply_to_message_id
            : null,
        aiGenerated: true,
      }
    );

    return ok(
      {
        message_id: result.messageId,
        whatsapp_message_id: result.whatsappMessageId,
        conversation_id: resolved.conversationId,
        contact_id: resolved.contactId,
        contact_created: resolved.contactCreated,
      },
      201
    );
  } catch (err) {
    if (err instanceof SendMessageError) {
      return fail(err.code, err.message, err.status);
    }
    return toApiErrorResponse(err);
  }
}
