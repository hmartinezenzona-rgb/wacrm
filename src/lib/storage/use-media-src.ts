'use client';

import { useEffect, useState } from 'react';

import { peekSignedMediaSrc, resolveMediaSrc } from './signed-media';

/**
 * The best URL for a chat-media object: the signed CDN URL when it can be
 * minted, the same-origin proxy otherwise.
 *
 * A URL whose signed form the server already sent (thread page seeding) is
 * returned on the FIRST render, with no null-then-src flash and no signing
 * request. Anything else starts as `null` so callers show their loading
 * state instead of firing a slow proxy request that the signed URL would
 * immediately replace.
 */
export function useMediaSrc(url: string | null | undefined): string | null {
  // The resolved URL is stored together with the input it belongs to. While a
  // new URL resolves, the derived return value is null, so callers keep their
  // loading state instead of showing the previous image.
  const [resolved, setResolved] = useState<{
    url: string | null | undefined;
    src: string | null;
  }>(() => ({ url, src: peekSignedMediaSrc(url) }));

  useEffect(() => {
    const seeded = peekSignedMediaSrc(url);
    if (seeded) {
      setResolved({ url, src: seeded });
      return;
    }
    let alive = true;
    void resolveMediaSrc(url).then((value) => {
      if (alive) setResolved({ url, src: value || null });
    });
    return () => {
      alive = false;
    };
  }, [url]);

  if (resolved.url === url) return resolved.src;
  // A new input that the page already seeded paints immediately as well.
  return peekSignedMediaSrc(url);
}
