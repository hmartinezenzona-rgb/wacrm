import { describe, expect, it } from "vitest";
import { createAvatar } from "@dicebear/core";
import * as notionists from "@dicebear/notionists";
import {
  AVATAR_BACKGROUNDS,
  AVATAR_HAIR_POOLS,
  contactAvatarDataUri,
} from "./contact-avatar";

const decoded = (uri: string) => decodeURIComponent(uri);
const backgroundOf = (uri: string) => {
  const hit = AVATAR_BACKGROUNDS.find((hex) => decoded(uri).toLowerCase().includes(`#${hex}`));
  return hit ?? null;
};
// The hair option is rendered as one group; a signature of the hair is the
// SVG generated with every other feature neutralised via the same seed.
const hairSignature = (hair: (typeof AVATAR_HAIR_POOLS.f)[number], seed: string) =>
  decoded(
    createAvatar(notionists, { seed, hair: [hair], backgroundColor: ["ffffff"] }).toDataUri(),
  );

describe("contactAvatarDataUri", () => {
  it("returns an SVG data URI", () => {
    const uri = contactAvatarDataUri("contact-1");
    expect(uri.startsWith("data:image/svg+xml")).toBe(true);
    expect(decodeURIComponent(uri)).toContain("<svg");
  });

  it("is stable for the same seed", () => {
    expect(contactAvatarDataUri("contact-1")).toBe(contactAvatarDataUri("contact-1"));
  });

  it("differs between seeds", () => {
    expect(contactAvatarDataUri("contact-1")).not.toBe(contactAvatarDataUri("contact-2"));
  });

  it("only uses the soft pastel palette for the background", () => {
    const svg = decodeURIComponent(contactAvatarDataUri("contact-3"));
    const palette = ["c0aede", "d1d4f9", "ffd5dc", "ffdfbf", "b6e3f4"];
    expect(palette.some((hex) => svg.toLowerCase().includes(`#${hex}`))).toBe(true);
  });
});

describe("avatar pools", () => {
  it("has the agreed sizes", () => {
    expect(AVATAR_HAIR_POOLS.f).toHaveLength(24);
    expect(AVATAR_HAIR_POOLS.m).toHaveLength(33);
    expect(AVATAR_HAIR_POOLS.n).toHaveLength(7);
    expect(AVATAR_BACKGROUNDS).toEqual([
      "c0aede", "d1d4f9", "ffd5dc", "ffdfbf", "b6e3f4", "c7f0db", "fff1b8", "e6d3f5",
    ]);
  });

  it("never shares a hair between pools", () => {
    const all = [...AVATAR_HAIR_POOLS.f, ...AVATAR_HAIR_POOLS.m, ...AVATAR_HAIR_POOLS.n];
    expect(new Set(all).size).toBe(64);
  });
});

describe("contactAvatarDataUri with gender and seq", () => {
  const SEED = "contact-xyz";

  it("falls back to the legacy output when gender or seq are missing", () => {
    const legacy = createAvatar(notionists, {
      seed: SEED,
      backgroundColor: ["c0aede", "d1d4f9", "ffd5dc", "ffdfbf", "b6e3f4"],
    }).toDataUri();
    expect(contactAvatarDataUri(SEED)).toBe(legacy);
    expect(contactAvatarDataUri(SEED, null, null)).toBe(legacy);
    expect(contactAvatarDataUri(SEED, "f", null)).toBe(legacy);
    expect(contactAvatarDataUri(SEED, undefined, 3)).toBe(legacy);
  });

  it("uses pool[(seq-1) % H] and palette[floor((seq-1)/H) % 8]", () => {
    const uri = contactAvatarDataUri(SEED, "f", 1);
    expect(backgroundOf(uri)).toBe(AVATAR_BACKGROUNDS[0]);
    const second = contactAvatarDataUri(SEED, "f", 25); // k=24 -> wraps hair, next background
    expect(backgroundOf(second)).toBe(AVATAR_BACKGROUNDS[1]);
    expect(contactAvatarDataUri(SEED, "f", 1)).toBe(uri);
  });

  it("memoises per gender and seq", () => {
    expect(contactAvatarDataUri(SEED, "f", 1)).not.toBe(contactAvatarDataUri(SEED, "m", 1));
    expect(contactAvatarDataUri(SEED, "f", 1)).not.toBe(contactAvatarDataUri(SEED, "f", 2));
  });

  it("feminine avatars never carry a beard", () => {
    for (let seq = 1; seq <= 24; seq++) {
      for (const seed of ["a", "b", "c", "d", "e", "f", "g", "h"]) {
        const uri = contactAvatarDataUri(seed, "f", seq);
        const expected = createAvatar(notionists, {
          seed,
          hair: [AVATAR_HAIR_POOLS.f[seq - 1]],
          backgroundColor: [AVATAR_BACKGROUNDS[0]],
          beardProbability: 0,
        }).toDataUri();
        expect(uri).toBe(expected);
      }
    }
  });

  it("neutral avatars never carry a beard and use the neutral pool", () => {
    const expected = createAvatar(notionists, {
      seed: SEED,
      hair: [AVATAR_HAIR_POOLS.n[0]],
      backgroundColor: [AVATAR_BACKGROUNDS[0]],
      beardProbability: 0,
    }).toDataUri();
    expect(contactAvatarDataUri(SEED, "n", 1)).toBe(expected);
  });

  it("masculine avatars use the masculine pool and keep the default beard odds", () => {
    const expected = createAvatar(notionists, {
      seed: SEED,
      hair: [AVATAR_HAIR_POOLS.m[2]],
      backgroundColor: [AVATAR_BACKGROUNDS[0]],
    }).toDataUri();
    expect(contactAvatarDataUri(SEED, "m", 3)).toBe(expected);
  });

  it.each(["f", "m", "n"] as const)(
    "gives %s contacts pairwise distinct hair+background for seq 1..H*8",
    (gender) => {
      const H = AVATAR_HAIR_POOLS[gender].length;
      const seen = new Set<string>();
      for (let seq = 1; seq <= H * 8; seq++) {
        const k = seq - 1;
        const hair = AVATAR_HAIR_POOLS[gender][k % H];
        const bg = AVATAR_BACKGROUNDS[Math.floor(k / H) % 8];
        const uri = contactAvatarDataUri(SEED, gender, seq);
        expect(backgroundOf(uri)).toBe(bg);
        seen.add(`${hair}|${bg}`);
      }
      expect(seen.size).toBe(H * 8);
    },
  );

  it("renders a different hair for every seq inside one pool", () => {
    const hairs = new Set<string>();
    for (let seq = 1; seq <= 24; seq++) {
      hairs.add(hairSignature(AVATAR_HAIR_POOLS.f[seq - 1], SEED));
    }
    expect(hairs.size).toBe(24);
  });
});
