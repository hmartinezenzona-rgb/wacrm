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
  const [src, setSrc] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setSrc(null);
    void resolveMediaSrc(url).then((resolved) => {
      if (alive) setSrc(resolved || null);
    });
    return () => {
      alive = false;
    };
  }, [url]);

  return src;
}
