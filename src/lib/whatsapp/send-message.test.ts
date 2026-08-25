import { afterEach, describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

import {
  sendMessageToConversation,
  uploadMediaForSend,
  SendMessageError,
  type SendMessageParams,
} from './send-message';

// A db that explodes if touched — these tests cover the param
// validation that MUST short-circuit before any query runs.
function noDb(): SupabaseClient {
  return {
    from() {
      throw new Error('db should not be queried for invalid params');
    },
  } as unknown as SupabaseClient;
}

async function expectSendError(
  params: SendMessageParams,
  status: number,
  messageMatch?: RegExp
) {
  await expect(
    sendMessageToConversation(noDb(), 'acct-1', params)
  ).rejects.toBeInstanceOf(SendMessageError);
  await sendMessageToConversation(noDb(), 'acct-1', params).catch(
    (e: SendMessageError) => {
      expect(e.status).toBe(status);
      if (messageMatch) expect(e.message).toMatch(messageMatch);
    }
  );
}

describe('sendMessageToConversation — param validation (pre-DB)', () => {
  const base = { conversationId: 'cv-1' };

  it('requires conversation_id and message_type', async () => {
    await expectSendError({ conversationId: '', messageType: 'text' }, 400);
    await expectSendError({ conversationId: 'cv-1', messageType: '' }, 400);
  });

  it('rejects an unsupported message_type', async () => {
    await expectSendError(
      { ...base, messageType: 'carrier-pigeon' },
      400,
      /Unsupported message_type/
    );
  });

  it('requires content_text for text messages', async () => {
    await expectSendError(
      { ...base, messageType: 'text' },
      400,
      /content_text is required/
    );
  });

  it('requires template_name for template messages', async () => {
    await expectSendError(
      { ...base, messageType: 'template' },
      400,
      /template_name is required/
    );
  });

  it('requires media_url for media kinds', async () => {
    for (const kind of ['image', 'video', 'document', 'audio']) {
      await expectSendError(
        { ...base, messageType: kind },
        400,
        /media_url is required/
      );
    }
  });

  it('rejects an over-long media caption (non-audio)', async () => {
    await expectSendError(
      {
        ...base,
        messageType: 'image',
        mediaUrl: 'https://x/y.jpg',
        contentText: 'a'.repeat(1025),
      },
      400,
      /1024-character limit/
    );
  });

  it('requires a valid interactive payload for interactive messages', async () => {
    // Missing payload entirely.
    await expectSendError(
      { ...base, messageType: 'interactive' },
      400,
      /payload is required/
    );
    // Too many buttons.
    await expectSendError(
      {
        ...base,
        messageType: 'interactive',
        interactivePayload: {
          kind: 'buttons',
          body: 'Pick one',
          buttons: [
            { id: 'a', title: 'A' },
            { id: 'b', title: 'B' },
            { id: 'c', title: 'C' },
            { id: 'd', title: 'D' },
          ],
        },
      },
      400,
      /at most 3 buttons/
    );
    // Over-long button title.
    await expectSendError(
      {
        ...base,
        messageType: 'interactive',
        interactivePayload: {
          kind: 'buttons',
          body: 'Pick one',
          buttons: [{ id: 'a', title: 'x'.repeat(21) }],
        },
      },
      400,
      /20-character limit/
    );
  });

  it('allows a long "caption" on audio (audio carries none) — so it reaches the DB', async () => {
    // Audio is exempt from the caption cap, so validation passes and we
    // proceed to the conversation lookup — proven by the stub throwing.
    const spy = vi.fn(() => {
      throw new Error('reached DB');
    });
    const db = { from: spy } as unknown as SupabaseClient;
    await expect(
      sendMessageToConversation(db, 'acct-1', {
        ...base,
        messageType: 'audio',
        mediaUrl: 'https://x/y.ogg',
        contentText: 'a'.repeat(2000),
      })
    ).rejects.toThrow('reached DB');
    expect(spy).toHaveBeenCalledWith('conversations');
  });
});

describe('SendMessageError', () => {
  it('carries a machine code and an HTTP status', () => {
    const e = new SendMessageError('meta_error', 'boom', 502);
    expect(e.code).toBe('meta_error');
    expect(e.status).toBe(502);
    expect(e).toBeInstanceOf(Error);
  });
});

// ============================================================
// Media upload — the link-vs-id decision.
//
// Handing Meta a `link` means Meta fetches the file at send time. When
// that fetch fails, Meta has ALREADY accepted the message and returned
// a wamid; the failure arrives minutes later as a `failed` status, long
// after the deal was closed as delivered on the strength of that
// acceptance. That is what happened on 24-ago-2026.
//
// Uploading first removes that window — but it must never make a send
// WORSE than it is today, so every give-up path falls back to the link.
// ============================================================

describe('uploadMediaForSend', () => {
  const MEDIA = 'https://cdn.example.com/account-1/captura.png';

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  /** Media fetch first, then the upload to Meta. */
  function fetchSequence(
    media: Partial<{ ok: boolean; type: string; length: string; bytes: number }>,
    upload?: { ok: boolean; body: unknown },
  ) {
    let call = 0;
    return vi.fn(async () => {
      call++;
      if (call === 1) {
        const headers = new Map<string, string>();
        if (media.type !== undefined) headers.set('content-type', media.type);
        if (media.length !== undefined) headers.set('content-length', media.length);
        return {
          ok: media.ok ?? true,
          status: media.ok === false ? 404 : 200,
          headers: { get: (k: string) => headers.get(k) ?? null },
          arrayBuffer: async () => new Uint8Array(media.bytes ?? 3).buffer,
        } as unknown as Response;
      }
      if (!upload) throw new Error('unexpected second fetch — no upload expected');
      return {
        ok: upload.ok,
        status: upload.ok ? 200 : 400,
        json: async () => upload.body,
      } as Response;
    });
  }

  it('uploads and returns the media id on the happy path', async () => {
    const fetchMock = fetchSequence(
      { type: 'image/png', length: '2048' },
      { ok: true, body: { id: 'media-abc' } },
    );
    vi.stubGlobal('fetch', fetchMock);

    const id = await uploadMediaForSend(MEDIA, 'phone-1', 'token-1');

    expect(id).toBe('media-abc');
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('falls back to the link when the media cannot be fetched', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.stubGlobal('fetch', fetchSequence({ ok: false }));

    expect(await uploadMediaForSend(MEDIA, 'phone-1', 'token-1')).toBeUndefined();
  });

  it('falls back when the object has no usable content-type', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.stubGlobal('fetch', fetchSequence({ type: 'application/octet-stream' }));

    expect(await uploadMediaForSend(MEDIA, 'phone-1', 'token-1')).toBeUndefined();
  });

  it('falls back — without buffering — when the file is over the cap', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const fetchMock = fetchSequence({
      type: 'video/mp4',
      length: String(64 * 1024 * 1024),
    });
    vi.stubGlobal('fetch', fetchMock);

    expect(await uploadMediaForSend(MEDIA, 'phone-1', 'token-1')).toBeUndefined();
    // Only the media fetch: it never reached the upload.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('falls back when Meta refuses the upload', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.stubGlobal(
      'fetch',
      fetchSequence(
        { type: 'image/png' },
        { ok: false, body: { error: { message: 'Unsupported media type' } } },
      ),
    );

    expect(await uploadMediaForSend(MEDIA, 'phone-1', 'token-1')).toBeUndefined();
  });
});
