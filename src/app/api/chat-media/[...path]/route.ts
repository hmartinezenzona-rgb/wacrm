// ============================================================
// GET /api/chat-media/<account-uuid>/<file>
//
// Same-origin proxy for the chat-media bucket, so the bucket can be
// private. Requires a session; the first folder must be the caller's own
// `account-<account_id>`; bytes are read with the service role (the
// account check above is the authorisation). Supports a single HTTP
// Range so <audio>/<video> can seek.
// ============================================================

import { NextResponse } from 'next/server';
import { requireRole, toErrorResponse } from '@/lib/auth/account';
import { parseChatMediaPath } from '@/lib/storage/chat-media';
import { downloadChatMedia } from '@/lib/storage/chat-media-server';

const BASE_HEADERS = {
  'Cache-Control': 'private, max-age=3600',
  'X-Content-Type-Options': 'nosniff',
  'Accept-Ranges': 'bytes',
};

/** Parse a single `bytes=a-b` / `bytes=a-` / `bytes=-n` range. */
function parseRange(header: string, size: number): { start: number; end: number } | 'invalid' {
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return 'invalid';
  let start: number;
  let end: number;
  if (m[1] === '') {
    const n = Number(m[2]);
    if (n === 0) return 'invalid';
    start = Math.max(size - n, 0);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start >= size || start > end) return 'invalid';
  return { start, end };
}

// The route params are not used: the path is re-derived from the raw URL
// so it is decoded exactly once, whatever the framework does to params.
export async function GET(request: Request) {
  try {
    const { accountId } = await requireRole('viewer');

    const path = parseChatMediaPath(new URL(request.url).pathname);
    if (!path) {
      return NextResponse.json({ error: 'Invalid media path' }, { status: 400 });
    }
    if (path.split('/')[0] !== `account-${accountId}`) {
      return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
    }

    const media = await downloadChatMedia(path, accountId);
    if (!media) {
      return NextResponse.json({ error: 'Not found' }, { status: 404 });
    }

    const size = media.bytes.byteLength;
    const rangeHeader = request.headers.get('range');
    if (rangeHeader) {
      const range = parseRange(rangeHeader, size);
      if (range === 'invalid') {
        return new Response(null, {
          status: 416,
          headers: { ...BASE_HEADERS, 'Content-Range': `bytes */${size}` },
        });
      }
      const slice = media.bytes.slice(range.start, range.end + 1);
      return new Response(slice, {
        status: 206,
        headers: {
          ...BASE_HEADERS,
          'Content-Type': media.contentType,
          'Content-Range': `bytes ${range.start}-${range.end}/${size}`,
          'Content-Length': String(slice.byteLength),
        },
      });
    }

    return new Response(media.bytes, {
      status: 200,
      headers: {
        ...BASE_HEADERS,
        'Content-Type': media.contentType,
        'Content-Length': String(size),
      },
    });
  } catch (error) {
    return toErrorResponse(error);
  }
}
