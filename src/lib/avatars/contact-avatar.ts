import { createAvatar } from "@dicebear/core";
import * as notionists from "@dicebear/notionists";

// Soft pastel backgrounds picked by the owner; the seed chooses one.
const BACKGROUND_COLORS = ["c0aede", "d1d4f9", "ffd5dc", "ffdfbf", "b6e3f4"];

// Bounded memo: a long inbox session can walk through thousands of contacts.
const MAX_CACHE_ENTRIES = 500;
const cache = new Map<string, string>();

/**
 * Illustrated default avatar (DiceBear "notionists") as an SVG data URI.
 * Generated locally and deterministically: nothing leaves the browser.
 * Pass a stable seed such as the contact id so the face survives renames.
 */
export function contactAvatarDataUri(seed: string): string {
  const cached = cache.get(seed);
  if (cached) return cached;

  const uri = createAvatar(notionists, {
    seed,
    backgroundColor: BACKGROUND_COLORS,
  }).toDataUri();

  if (cache.size >= MAX_CACHE_ENTRIES) {
    // Maps iterate in insertion order, so the first key is the oldest.
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(seed, uri);
  return uri;
}
