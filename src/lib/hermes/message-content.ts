// ============================================================
// Message payload for the Hermes chat.
//
// Hermes' API server takes OpenAI-style content: either a string or a list
// of parts, and it accepts images as `image_url` with a data: URL. The panel
// uses that to send a voucher or a screenshot the admin attaches.
//
// Kept out of the route so the rules can be tested without a Request.
// ============================================================

export type HermesTextPart = { type: 'text'; text: string };
export type HermesImagePart = { type: 'image_url'; image_url: { url: string } };
export type HermesPart = HermesTextPart | HermesImagePart;

export interface HermesMessage {
  role: 'user' | 'assistant';
  content: string | HermesPart[];
}

export const MAX_MESSAGES = 30;
export const MAX_CHARS = 8000;
/** One attachment per question: "mira este comprobante" is the real case. */
export const MAX_IMAGES_PER_MESSAGE = 1;
/** Decoded bytes, not base64 length. 1600 px JPEG lands well under this. */
export const MAX_IMAGE_BYTES = 3 * 1024 * 1024;
/** Only data: URLs. A remote URL would make the VPS fetch it — an SSRF hole. */
const IMAGE_DATA_URL = /^data:image\/(jpeg|png|webp);base64,([A-Za-z0-9+/]+={0,2})$/;

export class InvalidMessagesError extends Error {}

function decodedBytes(base64: string): number {
  // 4 base64 chars carry 3 bytes; padding is already excluded by the pattern.
  return Math.floor((base64.length * 3) / 4);
}

function cleanImagePart(part: unknown, role: HermesMessage['role']): HermesImagePart | null {
  const url = (part as { image_url?: { url?: unknown } }).image_url?.url;
  if (typeof url !== 'string' || !url) {
    throw new InvalidMessagesError('La imagen no trae URL.');
  }
  if (role !== 'user') {
    throw new InvalidMessagesError('Las imágenes solo pueden ir en un mensaje del usuario.');
  }
  const match = IMAGE_DATA_URL.exec(url);
  if (!match) {
    throw new InvalidMessagesError('La imagen debe ser JPEG, PNG o WebP en data: URL.');
  }
  if (decodedBytes(match[2]) > MAX_IMAGE_BYTES) {
    throw new InvalidMessagesError('La imagen supera el tamaño máximo.');
  }
  return { type: 'image_url', image_url: { url } };
}

function cleanParts(content: unknown[], role: HermesMessage['role']): string | HermesPart[] {
  const parts: HermesPart[] = [];
  let images = 0;
  for (const part of content) {
    const type = (part as { type?: unknown })?.type;
    if (type === 'text') {
      const text = (part as { text?: unknown }).text;
      if (typeof text !== 'string') throw new InvalidMessagesError('Parte de texto inválida.');
      if (text.trim()) parts.push({ type: 'text', text: text.slice(0, MAX_CHARS) });
      continue;
    }
    if (type === 'image_url') {
      if (++images > MAX_IMAGES_PER_MESSAGE) {
        throw new InvalidMessagesError('Solo se admite una imagen por mensaje.');
      }
      const image = cleanImagePart(part, role);
      if (image) parts.push(image);
      continue;
    }
    throw new InvalidMessagesError('Tipo de contenido no admitido.');
  }
  // A text-only list collapses back to a string: fewer moving parts upstream.
  if (parts.every((part) => part.type === 'text')) {
    return (parts as HermesTextPart[]).map((part) => part.text).join('\n');
  }
  return parts;
}

/**
 * Keep the last messages, drop junk, and enforce the text and image limits.
 * Throws `InvalidMessagesError` when a part is present but not acceptable.
 */
export function cleanMessages(value: unknown): HermesMessage[] {
  if (!Array.isArray(value)) return [];
  const out: HermesMessage[] = [];
  for (const item of value.slice(-MAX_MESSAGES)) {
    if (!item || typeof item !== 'object') continue;
    const role = (item as { role?: unknown }).role;
    const content = (item as { content?: unknown }).content;
    if (role !== 'user' && role !== 'assistant') continue;

    if (typeof content === 'string') {
      if (content.trim()) out.push({ role, content: content.slice(0, MAX_CHARS) });
      continue;
    }
    if (Array.isArray(content)) {
      const cleaned = cleanParts(content, role);
      const empty = typeof cleaned === 'string' && !cleaned;
      if (!empty) out.push({ role, content: cleaned });
    }
  }
  return out;
}
