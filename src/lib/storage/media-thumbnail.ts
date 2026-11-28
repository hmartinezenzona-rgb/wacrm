// ============================================================
// Thumbnails for inbound chat media.
//
// A WhatsApp photo is 100–400 KB; the thread only shows a bubble a
// couple of hundred pixels tall. Downloading the original to paint it
// is what made the inbox slow, so ingest also stores a small WebP
// sibling and the bubble asks for that one.
//
// The original is never re-encoded or replaced: the thumbnail is a new
// object under `thumbs/` in the same account prefix, and the stored
// `media_url` keeps pointing at the untouched original.
// ============================================================

/** Longest side of the thumbnail, in pixels. */
export const THUMBNAIL_MAX_SIDE = 360;

/** WebP quality. 65 is visually clean at this size and about a tenth of the original. */
const THUMBNAIL_QUALITY = 65;

// Deliberately not a uuid check: the point is the shape (one account prefix,
// one file name, no extra segments), not the account id format.
const ACCOUNT_OBJECT_PATH = /^(account-[A-Za-z0-9_-]+)\/([^/]+)$/;

export interface MediaThumbnail {
  /** Object path of the WebP sibling inside the chat-media bucket. */
  path: string;
  data: Buffer;
  mime: 'image/webp';
  /** Dimensions of the thumbnail itself. */
  width: number;
  height: number;
  /** Dimensions of the original as displayed (EXIF orientation applied). */
  sourceWidth: number;
  sourceHeight: number;
}

/**
 * The outcome of a thumbnail attempt:
 *   - `null` when the object is not an image at all (nothing to do, and
 *     nothing to report as an error);
 *   - `{ error }` when it looked like an image but could not be processed;
 *   - the thumbnail otherwise.
 */
export type ThumbnailOutcome = MediaThumbnail | { error: string } | null;

/**
 * `account-<uuid>/<base>.<ext>` becomes `account-<uuid>/thumbs/<base>.webp`.
 *
 * Deterministic, so a retry overwrites the same object instead of
 * littering the bucket. Returns null for anything that is not a plain
 * object path inside an account prefix — traversal and absolute paths
 * included.
 */
export function thumbnailPathFor(path: string | null | undefined): string | null {
  if (!path || path.startsWith('/') || path.includes('..')) return null;
  const match = ACCOUNT_OBJECT_PATH.exec(path);
  if (!match) return null;
  const base = match[2].replace(/\.[^.]*$/, '');
  if (!base) return null;
  return `${match[1]}/thumbs/${base}.webp`;
}

/** EXIF orientations 5–8 rotate by 90°, so the displayed size is swapped. */
function isQuarterTurn(orientation: number | undefined): boolean {
  return orientation !== undefined && orientation >= 5 && orientation <= 8;
}

/**
 * Build the WebP sibling for `bytes`. Never throws: a broken image comes
 * back as `{ error }` so the caller can store `ready` with a note and
 * still show the original, which is exactly what the panel does today.
 */
export async function makeThumbnail(
  path: string,
  bytes: Buffer,
): Promise<ThumbnailOutcome> {
  const thumbPath = thumbnailPathFor(path);
  if (!thumbPath) return null;

  // Imported lazily: only the ingest path needs the native module.
  const sharpModule = await import('sharp');
  const sharp = sharpModule.default;

  let orientation: number | undefined;
  let rawWidth: number | undefined;
  let rawHeight: number | undefined;
  try {
    const meta = await sharp(bytes).metadata();
    if (!meta.format || !meta.width || !meta.height) return null;
    orientation = meta.orientation;
    rawWidth = meta.width;
    rawHeight = meta.height;
  } catch {
    // sharp cannot read even the header: not an image.
    return null;
  }

  try {
    const { data, info } = await sharp(bytes)
      .rotate()
      .resize({
        width: THUMBNAIL_MAX_SIDE,
        height: THUMBNAIL_MAX_SIDE,
        fit: 'inside',
        withoutEnlargement: true,
      })
      .webp({ quality: THUMBNAIL_QUALITY, effort: 4 })
      .toBuffer({ resolveWithObject: true });

    const swap = isQuarterTurn(orientation);
    return {
      path: thumbPath,
      data,
      mime: 'image/webp',
      width: info.width,
      height: info.height,
      sourceWidth: swap ? rawHeight! : rawWidth!,
      sourceHeight: swap ? rawWidth! : rawHeight!,
    };
  } catch (thrown) {
    return {
      error: thrown instanceof Error ? thrown.message : String(thrown),
    };
  }
}
