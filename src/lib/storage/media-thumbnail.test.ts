import { describe, expect, it } from 'vitest';
import sharp from 'sharp';

import { makeThumbnail, thumbnailPathFor } from './media-thumbnail';

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const PATH = `account-${ACCT}/1700000000000-wa-1.jpg`;

/** A real PNG, big enough that the longest side must actually be scaled. */
async function png(width: number, height: number): Promise<Buffer> {
  const raw = Buffer.alloc(width * height * 3, 120);
  return sharp(raw, { raw: { width, height, channels: 3 } }).png().toBuffer();
}

describe('thumbnailPathFor', () => {
  it('puts the thumbnail next to the original, as webp', () => {
    expect(thumbnailPathFor(PATH)).toBe(`account-${ACCT}/thumbs/1700000000000-wa-1.webp`);
  });

  it('keeps the base name even when the original has dots in it', () => {
    expect(thumbnailPathFor(`account-${ACCT}/a.b.c.pdf`)).toBe(`account-${ACCT}/thumbs/a.b.c.webp`);
  });

  it('refuses paths that are not inside an account prefix', () => {
    expect(thumbnailPathFor('thumbs/x.jpg')).toBeNull();
    expect(thumbnailPathFor(`account-${ACCT}`)).toBeNull();
    expect(thumbnailPathFor('')).toBeNull();
    expect(thumbnailPathFor(null)).toBeNull();
  });

  it('refuses traversal and absolute paths', () => {
    expect(thumbnailPathFor(`account-${ACCT}/../../etc/passwd`)).toBeNull();
    expect(thumbnailPathFor(`account-${ACCT}/a/../../b.jpg`)).toBeNull();
    expect(thumbnailPathFor('/etc/passwd')).toBeNull();
  });
});

describe('makeThumbnail', () => {
  it('produces a webp whose longest side is 360, reporting the original size', async () => {
    const source = await png(800, 600);
    const out = await makeThumbnail(PATH, source);

    expect('error' in out!).toBe(false);
    const thumb = out as Exclude<typeof out, { error: string } | null>;
    expect(thumb.path).toBe(`account-${ACCT}/thumbs/1700000000000-wa-1.webp`);
    expect(thumb.mime).toBe('image/webp');
    expect(Math.max(thumb.width, thumb.height)).toBeLessThanOrEqual(360);
    expect(thumb.width).toBe(360);
    expect(thumb.height).toBe(270);
    // What the caller stores as the message's own dimensions.
    expect(thumb.sourceWidth).toBe(800);
    expect(thumb.sourceHeight).toBe(600);

    const meta = await sharp(thumb.data).metadata();
    expect(meta.format).toBe('webp');
    expect(meta.width).toBe(360);
  });

  it('does not enlarge a small image', async () => {
    const source = await png(200, 100);
    const out = await makeThumbnail(PATH, source);
    const thumb = out as Exclude<typeof out, { error: string } | null>;
    expect(thumb.width).toBe(200);
    expect(thumb.height).toBe(100);
  });

  it('applies the EXIF orientation before measuring, so portrait photos stay portrait', async () => {
    // 400x200 with orientation 6: the displayed image is 200x400 (portrait).
    const source = await sharp({
      create: { width: 400, height: 200, channels: 3, background: { r: 10, g: 120, b: 60 } },
    })
      .jpeg()
      .withMetadata({ orientation: 6 })
      .toBuffer();
    const out = await makeThumbnail(PATH, source);
    const thumb = out as Exclude<typeof out, { error: string } | null>;
    expect(thumb.height).toBeGreaterThan(thumb.width);
    expect(thumb.sourceHeight).toBe(400);
    expect(thumb.sourceWidth).toBe(200);
  });

  it('returns null for bytes that are not an image', async () => {
    const out = await makeThumbnail(PATH, Buffer.from('this is not an image'));
    expect(out).toBeNull();
  });

  it('returns an error instead of throwing when the image is truncated', async () => {
    const source = await png(400, 400);
    const truncated = source.subarray(0, Math.floor(source.length / 3));
    const out = await makeThumbnail(PATH, truncated);
    expect(out).not.toBeNull();
    expect(out).toHaveProperty('error');
  });

  it('never modifies the caller buffer', async () => {
    const source = await png(400, 300);
    const before = Buffer.from(source);
    await makeThumbnail(PATH, source);
    expect(source.equals(before)).toBe(true);
  });
});
