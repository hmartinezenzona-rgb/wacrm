// ============================================================
// Delivery proof — the file rules.
//
// A "delivery proof" is the screenshot of the transfer that the
// operator sends the customer when a remittance is handed over.
// Until now they pasted it into the inbox by hand and then went
// back to the board to drag the deal; this module backs the panel
// that lets them prepare it on the deal itself.
//
// Everything here is pure and transport-free so it can be tested
// without a browser: no Supabase, no fetch, no DOM. The component
// owns the React state, this owns the rules.
//
// Why the rules are stricter than the inbox composer's:
//
//   · Narrower types. The inbox accepts anything the `chat-media`
//     bucket allows; a proof is a screenshot, so PNG/JPEG/WEBP and
//     nothing else. HEIC is deliberately out of the MVP — the
//     bucket would reject it anyway (migration 023 doesn't
//     allow-list it), so accepting it here would only move the
//     failure later and confuse the operator.
//
//   · Magic bytes, not just `file.type`. The browser's MIME is a
//     claim, not a fact, and `chat-media` is a PUBLIC bucket: a
//     mislabelled file lands on an unauthenticated URL. Eight bytes
//     of header is cheap insurance.
//
//   · A generic filename. `buildMediaPath` keeps the original name
//     in the object path, and that path is public. A screenshot
//     saved as `transferencia-juan-perez-4532.png` would publish
//     the customer's name in a URL. Proofs upload as
//     `prueba-entrega.<ext>`.
// ============================================================

import { MEDIA_MAX_BYTES_BY_KIND } from "@/lib/storage/upload-media";

/** 5 MB — Meta's image cap, same ceiling the inbox composer enforces. */
export const PROOF_MAX_BYTES = MEDIA_MAX_BYTES_BY_KIND.image;

/** The three formats a screenshot realistically arrives in. */
export const PROOF_IMAGE_KINDS = ["png", "jpeg", "webp"] as const;
export type ProofImageKind = (typeof PROOF_IMAGE_KINDS)[number];

/** `accept` attribute for the file picker, and the MIME allow-list. */
export const PROOF_ACCEPTED_MIME = [
  "image/png",
  "image/jpeg",
  "image/webp",
] as const;

const EXTENSION: Record<ProofImageKind, string> = {
  png: "png",
  jpeg: "jpg",
  webp: "webp",
};

const MIME_TO_KIND: Record<string, ProofImageKind> = {
  "image/png": "png",
  "image/jpeg": "jpeg",
  "image/webp": "webp",
};

/**
 * Why a file was turned away. The component maps each to a message;
 * keeping them as codes means the copy can change without touching
 * the rules (or the tests).
 */
export type ProofRejection =
  | "empty" // zero bytes, or no file at all
  | "mime" // the browser says it isn't one of the three
  | "size" // over 5 MB
  | "signature"; // the bytes disagree with the extension/MIME

export type ProofValidation =
  | { ok: true; kind: ProofImageKind; uploadName: string }
  | { ok: false; reason: ProofRejection };

/**
 * The slice of `File` this module needs. Typing it structurally (rather
 * than as the DOM `File`) is what lets the tests run under vitest's
 * `node` environment without a fake DOM.
 */
export interface ProofFileLike {
  readonly type: string;
  readonly size: number;
  arrayBuffer(): Promise<ArrayBuffer>;
}

// Header signatures. Longest first isn't needed — each is unambiguous.
//   PNG   89 50 4E 47 0D 0A 1A 0A
//   JPEG  FF D8 FF                       (SOI + first marker)
//   WEBP  52 49 46 46 ?? ?? ?? ?? 57 45 42 50   "RIFF"<size>"WEBP"
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const JPEG_MAGIC = [0xff, 0xd8, 0xff];
const RIFF_MAGIC = [0x52, 0x49, 0x46, 0x46];
const WEBP_MAGIC = [0x57, 0x45, 0x42, 0x50];

function startsWith(bytes: Uint8Array, magic: number[], offset = 0): boolean {
  if (bytes.length < offset + magic.length) return false;
  return magic.every((b, i) => bytes[offset + i] === b);
}

/**
 * Identify an image from its leading bytes, or `null` when it is none
 * of the three. Only the first 12 bytes are ever inspected.
 */
export function detectImageKind(bytes: Uint8Array): ProofImageKind | null {
  if (startsWith(bytes, PNG_MAGIC)) return "png";
  if (startsWith(bytes, JPEG_MAGIC)) return "jpeg";
  // WEBP needs both ends of the 12-byte RIFF header: "RIFF" alone is
  // also AVI and WAV.
  if (startsWith(bytes, RIFF_MAGIC) && startsWith(bytes, WEBP_MAGIC, 8)) {
    return "webp";
  }
  return null;
}

/**
 * The name a proof is uploaded under. Deliberately carries nothing
 * about the customer, the sender, the amount or the phone — the
 * `chat-media` object path is publicly readable.
 */
export function proofUploadName(kind: ProofImageKind): string {
  return `prueba-entrega.${EXTENSION[kind]}`;
}

/**
 * Full check: declared MIME, size, then the actual bytes.
 *
 * Order matters. MIME and size are free; reading the header is not,
 * so a 4 GB video is rejected on its declared type before anything
 * is read into memory.
 *
 * The byte check must also AGREE with the declared MIME. A real PNG
 * announced as `image/jpeg` is rejected: the bucket stores what the
 * browser declared, so Meta would later be handed a file whose
 * Content-Type contradicts its contents.
 */
export async function validateProofFile(
  file: ProofFileLike | null | undefined,
): Promise<ProofValidation> {
  if (!file || file.size === 0) return { ok: false, reason: "empty" };

  const declared = MIME_TO_KIND[file.type];
  if (!declared) return { ok: false, reason: "mime" };

  if (file.size > PROOF_MAX_BYTES) return { ok: false, reason: "size" };

  let head: Uint8Array;
  try {
    head = new Uint8Array(await file.arrayBuffer()).subarray(0, 12);
  } catch {
    return { ok: false, reason: "signature" };
  }

  const actual = detectImageKind(head);
  if (!actual || actual !== declared) {
    return { ok: false, reason: "signature" };
  }

  return { ok: true, kind: actual, uploadName: proofUploadName(actual) };
}

// ---------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------

/** The slice of `DataTransfer` this module needs. */
export interface ClipboardLike {
  files?: ArrayLike<File> | null;
  items?: ArrayLike<{ kind: string; type: string }> | null;
}

/**
 * The first image file on the clipboard, or `null`.
 *
 * `null` is the signal to leave the paste alone: pasting text into the
 * note must keep working exactly as the browser does it. Same contract
 * as the inbox composer's `handlePaste`, narrowed to images.
 */
export function pickPastedImage(data: ClipboardLike | null): File | null {
  const files = data?.files;
  if (!files || files.length === 0) return null;
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    if (file && typeof file.type === "string" && file.type.startsWith("image/")) {
      return file;
    }
  }
  return null;
}

// ---------------------------------------------------------------
// The draft
// ---------------------------------------------------------------

/**
 * A proof prepared but not yet sent. It lives in React state for the
 * length of the session and nowhere else — not Storage, not
 * localStorage, not the database.
 *
 * `dealId` is part of the draft on purpose. Drafts are held in a map
 * keyed by deal, and carrying the id inside the value too means a
 * mis-keyed lookup can be caught rather than silently sending deal A's
 * screenshot to deal B's customer.
 */
export interface DeliveryProofDraft {
  dealId: string;
  file: File;
  kind: ProofImageKind;
  /** Object URL for the thumbnail. Must be revoked when the draft dies. */
  previewUrl: string;
  /** Optional note; travels as the image caption, never to `deals.notes`. */
  caption: string;
  /**
   * Set once the image has actually reached the customer. Its presence
   * means "do not send this again" — the retry after a failed stage
   * update only writes `stage_id`.
   */
  sentWamid?: string;
}

/**
 * Is this draft the one for `dealId`? Guards the A-must-never-leak-into-B
 * invariant at the point of use.
 */
export function draftBelongsTo(
  draft: DeliveryProofDraft | null | undefined,
  dealId: string,
): draft is DeliveryProofDraft {
  return !!draft && !!dealId && draft.dealId === dealId;
}
