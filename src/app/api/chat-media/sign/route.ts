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
import { isChatMediaPathOfAccount, parseChatMediaPath } from '@/lib/storage/chat-media';
import { supabaseAdmin } from '@/lib/flows/admin-client';

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

    // Path per original URL, skipping anything outside this account.
    const byPath = new Map<string, string[]>();
    for (const url of urls as string[]) {
      const path = parseChatMediaPath(url);
      if (!path || !isChatMediaPathOfAccount(path, accountId)) continue;
      const originals = byPath.get(path) ?? [];
      originals.push(url);
      byPath.set(path, originals);
    }

    if (byPath.size === 0) {
      return NextResponse.json({ signed: {}, expiresIn: SIGNED_URL_TTL_SECONDS });
    }

    const { data, error } = await supabaseAdmin()
      .storage.from('chat-media')
      .createSignedUrls([...byPath.keys()], SIGNED_URL_TTL_SECONDS);

    if (error || !data) {
      console.error('[chat-media sign] could not sign batch:', error?.message ?? 'no data');
      return NextResponse.json({ error: 'Could not sign media' }, { status: 502 });
    }

    const signed: Record<string, string> = {};
    for (const row of data) {
      if (!row.signedUrl || !row.path) continue;
      for (const original of byPath.get(row.path) ?? []) {
        signed[original] = row.signedUrl;
      }
    }

    return NextResponse.json(
      { signed, expiresIn: SIGNED_URL_TTL_SECONDS },
      { headers: { 'Cache-Control': 'private, no-store' } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
