import { createAvatar } from "@dicebear/core";
import * as notionists from "@dicebear/notionists";

export type AvatarGender = "f" | "m" | "n";
type Hair = NonNullable<notionists.Options["hair"]>[number];

// Soft pastel backgrounds picked by the owner. Contacts with a known
// (gender, seq) walk through all eight in order; legacy seeds only use the
// first five, exactly as before.
export const AVATAR_BACKGROUNDS = [
  "c0aede",
  "d1d4f9",
  "ffd5dc",
  "ffdfbf",
  "b6e3f4",
  "c7f0db",
  "fff1b8",
  "e6d3f5",
] as const;
const LEGACY_BACKGROUNDS = AVATAR_BACKGROUNDS.slice(0, 5);

// notionists `hair` values, classified by eye from a rendered sheet of the 64
// hairs. Beards are only allowed for the masculine pool.
export const AVATAR_HAIR_POOLS: Record<AvatarGender, readonly Hair[]> = {
  f: [
    "variant02", "variant04", "variant08", "variant10", "variant11", "variant23",
    "variant24", "variant28", "variant29", "variant36", "variant37", "variant39",
    "variant41", "variant43", "variant45", "variant46", "variant47", "variant48",
    "variant57", "variant58", "variant59", "variant61", "variant62", "variant63",
  ],
  m: [
    "variant01", "variant03", "variant05", "variant06", "variant07", "variant09",
    "variant12", "variant13", "variant15", "variant16", "variant17", "variant18",
    "variant19", "variant21", "variant22", "variant25", "variant26", "variant27",
    "variant31", "variant33", "variant34", "variant35", "variant38", "variant44",
    "variant49", "variant50", "variant51", "variant52", "variant53", "variant54",
    "variant55", "variant56", "variant60",
  ],
  n: ["variant14", "variant20", "variant30", "variant32", "variant40", "variant42", "hat"],
};

// Bounded memo: a long inbox session can walk through thousands of contacts.
const MAX_CACHE_ENTRIES = 500;
const cache = new Map<string, string>();

/**
 * Illustrated default avatar (DiceBear "notionists") as an SVG data URI.
 * Generated locally and deterministically: nothing leaves the browser.
 * Pass a stable seed such as the contact id so the face survives renames.
 *
 * With the contact's `avatar_gender` and `avatar_seq` the hair follows the
 * name's gender and hair+background never repeat inside a gender group (up
 * to pool size x 8 contacts). Without them it is a pure hash of the seed.
 */
export function contactAvatarDataUri(
  seed: string,
  gender?: AvatarGender | null,
  seq?: number | null,
): string {
  const pool = gender ? AVATAR_HAIR_POOLS[gender] : undefined;
  const indexed = pool !== undefined && typeof seq === "number" && Number.isInteger(seq) && seq >= 1;
  const key = indexed ? `${seed}|${gender}|${seq}` : seed;

  const cached = cache.get(key);
  if (cached) return cached;

  let uri: string;
  if (indexed) {
    const k = seq - 1;
    uri = createAvatar(notionists, {
      seed,
      hair: [pool[k % pool.length]],
      backgroundColor: [AVATAR_BACKGROUNDS[Math.floor(k / pool.length) % AVATAR_BACKGROUNDS.length]],
      ...(gender === "m" ? {} : { beardProbability: 0 }),
    }).toDataUri();
  } else {
    uri = createAvatar(notionists, {
      seed,
      backgroundColor: [...LEGACY_BACKGROUNDS],
    }).toDataUri();
  }

  if (cache.size >= MAX_CACHE_ENTRIES) {
    // Maps iterate in insertion order, so the first key is the oldest.
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, uri);
  return uri;
}
