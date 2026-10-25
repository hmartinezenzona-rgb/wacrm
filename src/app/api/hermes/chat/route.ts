// ============================================================
// POST /api/hermes/chat
//
// Talks to the Hermes API server (OpenAI-compatible) that runs on the
// owner's Hermes VPS, reached through the SSH tunnel on 127.0.0.1:18643.
// Only admins can chat with it: Hermes has read-only CRM tools and sees the
// business data. The browser never touches the Hermes key: this route adds it
// server-side.
// ============================================================

import { NextResponse } from 'next/server';

import { requireRole, toErrorResponse } from '@/lib/auth/account';
import { InvalidMessagesError, cleanMessages } from '@/lib/hermes/message-content';

export const maxDuration = 120;
export const runtime = 'nodejs';

/**
 * One compressed screenshot plus the conversation stays far below this. It is
 * the cheap guard: the body is parsed after it, so a giant one never lands.
 */
const MAX_BODY_BYTES = 6 * 1024 * 1024;

export async function POST(request: Request): Promise<Response> {
  try {
    await requireRole('admin');
  } catch (err) {
    return toErrorResponse(err);
  }

  const length = Number(request.headers.get('content-length') ?? '');
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return NextResponse.json({ error: 'El mensaje es demasiado grande.' }, { status: 413 });
  }

  const body = (await request.json().catch(() => null)) as { messages?: unknown } | null;
  let messages;
  try {
    messages = cleanMessages(body?.messages);
  } catch (err) {
    if (err instanceof InvalidMessagesError) {
      return NextResponse.json({ error: err.message }, { status: 400 });
    }
    throw err;
  }
  if (messages.length === 0) {
    return NextResponse.json({ error: 'messages is required' }, { status: 400 });
  }

  const base = process.env.HERMES_API_URL;
  const key = process.env.HERMES_API_KEY;
  if (!base || !key) {
    return NextResponse.json(
      { error: 'Hermes no está configurado en el panel (HERMES_API_URL / HERMES_API_KEY).' },
      { status: 503 },
    );
  }

  let response: Response;
  try {
    response = await fetch(`${base.replace(/\/$/, '')}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: process.env.HERMES_API_MODEL || 'hermes',
        messages,
        stream: false,
      }),
      signal: AbortSignal.timeout(110_000),
    });
  } catch (err) {
    console.error('[hermes chat] request failed:', err);
    return NextResponse.json({ error: 'No se pudo contactar a Hermes.' }, { status: 502 });
  }

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    console.error('[hermes chat] upstream error', response.status, detail.slice(0, 300));
    return NextResponse.json(
      { error: `Hermes respondió ${response.status}.` },
      { status: 502 },
    );
  }

  const data = (await response.json().catch(() => null)) as
    | { choices?: Array<{ message?: { content?: unknown } }> }
    | null;
  const reply = data?.choices?.[0]?.message?.content;
  if (typeof reply !== 'string') {
    return NextResponse.json({ error: 'Hermes devolvió una respuesta vacía.' }, { status: 502 });
  }
  return NextResponse.json({ reply });
}
