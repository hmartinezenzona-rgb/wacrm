'use client';

import { useEffect, useState } from 'react';

import { resolveMediaSrc } from './signed-media';

/**
 * The best URL for a chat-media object: the signed CDN URL when it can be
 * minted, the same-origin proxy otherwise. Starts as `null` so callers show
 * their loading state instead of firing a slow proxy request that the signed
 * URL would immediately replace.
 */
export function useMediaSrc(url: string | null | undefined): string | null {
  // The resolved URL is stored together with the input it belongs to. While a
  // new URL resolves, the derived return value is null, so callers keep their
  // loading state instead of showing the previous image.
  const [resolved, setResolved] = useState<{
    url: string | null | undefined;
    src: string | null;
  }>({ url, src: null });

  useEffect(() => {
    let alive = true;
    void resolveMediaSrc(url).then((value) => {
      if (alive) setResolved({ url, src: value || null });
    });
    return () => {
      alive = false;
    };
  }, [url]);

  return resolved.url === url ? resolved.src : null;
}
