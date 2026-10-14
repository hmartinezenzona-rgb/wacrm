import { formatPhoneForDisplay, normalizePhone } from "@/lib/whatsapp/phone-utils";

export interface ExportableContact {
  name?: string | null;
  phone?: string | null;
  email?: string | null;
}

export interface VCardResult {
  /** The full .vcf text (CRLF line endings), "" when nothing is exportable. */
  vcf: string;
  exported: number;
  /** Contacts dropped because they have no usable phone digits. */
  skipped: number;
}

/** RFC 2426 / 6350 text escaping: backslash, comma, semicolon, newlines. */
function escapeText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/\r\n|\r|\n/g, "\\n")
    .replace(/,/g, "\\,")
    .replace(/;/g, "\;");
}

/**
 * Fold a content line at 75 octets (UTF-8), never splitting a character.
 * Continuation lines start with one space, which counts toward the limit.
 */
function foldLine(line: string): string {
  const MAX = 75;
  if (Buffer.byteLength(line, "utf8") <= MAX) return line;
  const parts: string[] = [];
  let current = "";
  let size = 0;
  for (const ch of line) {
    const chSize = Buffer.byteLength(ch, "utf8");
    const limit = parts.length === 0 ? MAX : MAX - 1;
    if (size + chSize > limit) {
      parts.push(current);
      current = "";
      size = 0;
    }
    current += ch;
    size += chSize;
  }
  if (current) parts.push(current);
  return parts.join("\r\n ");
}

/**
 * Build a vCard 3.0 file. The display name is "<prefix> - <name>" so every
 * exported contact can be found in WhatsApp by searching the prefix.
 *
 * N puts the whole display name in the given-name slot (family empty):
 * Android/iOS build the shown name from N when it is present, and splitting
 * the prefix into the family part would render "Juan Nuevos -" or reorder it
 * when sorting. Keeping it all in the given name displays exactly FN.
 */
export function buildVCard(
  contacts: ExportableContact[],
  { prefix }: { prefix: string },
): VCardResult {
  const brand = prefix.trim();
  const cards: string[] = [];
  let skipped = 0;

  for (const c of contacts) {
    const digits = normalizePhone(c.phone ?? "");
    if (!digits) {
      skipped++;
      continue;
    }
    const name = (c.name ?? "").trim() || formatPhoneForDisplay(digits);
    const display = brand ? `${brand} - ${name}` : name;
    const lines = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      `FN:${escapeText(display)}`,
      `N:;${escapeText(display)};;;`,
      `TEL;TYPE=CELL:+${digits}`,
    ];
    const email = (c.email ?? "").trim();
    if (email) lines.push(`EMAIL:${escapeText(email)}`);
    lines.push("END:VCARD");
    cards.push(lines.map(foldLine).join("\r\n"));
  }

  return {
    vcf: cards.length ? cards.join("\r\n") + "\r\n" : "",
    exported: cards.length,
    skipped,
  };
}

/** "contactos-<safe prefix>.vcf"; accents kept, FS-unsafe characters removed. */
export function exportFileName(prefix: string): string {
  const safe = prefix
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "")
    .trim();
  return safe ? `contactos-${safe}.vcf` : "contactos.vcf";
}

export function defaultPrefix(selectedTagNames: string[]): string {
  return selectedTagNames.join(" ").trim();
}

/** PostgREST caps a response at ~1000 rows. */
export const EXPORT_BATCH_SIZE = 1000;

/** Collect every row of a paged source; stops at the first short batch. */
export async function fetchAllInBatches<T>(
  fetchPage: (offset: number, limit: number) => Promise<{ rows: T[] }>,
  batchSize: number = EXPORT_BATCH_SIZE,
): Promise<T[]> {
  const all: T[] = [];
  for (let offset = 0; ; offset += batchSize) {
    const { rows } = await fetchPage(offset, batchSize);
    all.push(...rows);
    if (rows.length < batchSize) return all;
  }
}
