// ============================================================
// POST /api/chat-media/sign
//
// Mints short-lived signed URLs for the chat-media objects the caller is
// about to render, so the browser can fetch them straight from Supabase's
// CDN instead of pulling every byte through this server. One request signs
// a whole batch: Storage charges one HTTP call per createSignedUrl, so a
// per-image route would just move the queue.
//
// The proxy `/api/chat-media/<path>` stays as the fallback: if signing
// fails, or a URL is not chat-media, the client keeps using it.
//
// Body: { urls: string[] } — stored media_url values (public, signed or
// proxy shape). Response: { signed: { [originalUrl]: signedUrl },
// expiresIn }. Objects of another account are skipped, never signed.
// ============================================================

import { NextResponse } from 'next/server';

import { requireRole, toErrorResponse } from '@/lib/auth/account';
import { signChatMediaUrls } from '@/lib/storage/chat-media-server';

/** Long enough for a long chat session; the client re-signs with a margin. */
const SIGNED_URL_TTL_SECONDS = 3600;
/** Storage accepts 500 per call; keep a margin under the body limit. */
const MAX_URLS = 500;

export async function POST(request: Request) {
  try {
    const { accountId } = await requireRole('viewer');

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      console.warn('[chat-media sign] body is not JSON');
      return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
    }

    const raw = (body as { urls?: unknown } | null)?.urls;
    const urls = Array.isArray(raw) ? raw.filter((u): u is string => typeof u === 'string' && u.length > 0) : [];
    if (urls.length === 0 || urls.length > MAX_URLS) {
      // Diagnostics for the first real traffic: a 400 here leaves the client
      // on the proxy, so knowing the shape matters more than the message.
      console.warn('[chat-media sign] rejected body', JSON.stringify({
        isArray: Array.isArray(raw), count: Array.isArray(raw) ? raw.length : null, kept: urls.length,
      }));
      return NextResponse.json({ error: 'urls must be a non-empty array of strings' }, { status: 400 });
    }

    // One Storage call for the whole batch; foreign and non chat-media
    // URLs are skipped by the shared helper (never signed).
    const { signed, expiresIn, ok } = await signChatMediaUrls(
      urls as string[],
      accountId,
      SIGNED_URL_TTL_SECONDS,
    );

    if (!ok) {
      return NextResponse.json({ error: 'Could not sign media' }, { status: 502 });
    }

    return NextResponse.json(
      { signed, expiresIn },
      { headers: { 'Cache-Control': 'private, no-store' } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
