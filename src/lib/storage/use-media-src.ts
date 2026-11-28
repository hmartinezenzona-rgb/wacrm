'use client';

import { useEffect, useState, useSyncExternalStore } from 'react';

import {
  peekSignedMediaSrc,
  resolveMediaSrc,
  subscribeMediaCache,
} from './signed-media';

/**
 * The best URL for a chat-media object: the signed CDN URL when it can be
 * minted, the same-origin proxy otherwise.
 *
 * A URL whose signed form the server already sent (thread page seeding) is
 * returned on the FIRST render, with no null-then-src flash and no signing
 * request. The seed lives in a module cache that is read through
 * `useSyncExternalStore`, so invalidating a signature (a stale URL that
 * fired `error`) re-renders every component using it; deriving it inline
 * would be a stale read that never updates.
 *
 * Anything else starts as `null` so callers show their loading state
 * instead of firing a slow proxy request that the signed URL would
 * immediately replace.
 */
export function useMediaSrc(url: string | null | undefined): string | null {
  const seeded = useSyncExternalStore(
    subscribeMediaCache,
    () => peekSignedMediaSrc(url),
    // Server render: the cache is empty there, so the seeded value is null
    // and the client paints it after hydration.
    () => null,
  );

  // The resolved URL is stored together with the input it belongs to. While a
  // new URL resolves, the derived return value is null, so callers keep their
  // loading state instead of showing the previous image.
  const [resolved, setResolved] = useState<{
    url: string | null | undefined;
    src: string | null;
  }>(() => ({ url, src: null }));

  useEffect(() => {
    // A seeded URL is already paintable and needs no request.
    if (seeded) return;
    let alive = true;
    void resolveMediaSrc(url).then((value) => {
      if (alive) setResolved({ url, src: value || null });
    });
    return () => {
      alive = false;
    };
  }, [url, seeded]);

  if (seeded) return seeded;
  if (resolved.url === url) return resolved.src;
  return null;
}
