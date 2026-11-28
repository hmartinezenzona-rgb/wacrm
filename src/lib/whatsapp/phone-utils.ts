/**
 * Sanitize phone number for Meta WhatsApp API.
 * Meta requires digits only — no + prefix, no spaces, no dashes.
 * e.g. "+370 63949836" → "37063949836"
 */
export function sanitizePhoneForMeta(phone: string): string {
  if (!phone) return ''
  return phone.replace(/\D/g, '')
}

/**
 * Normalize phone number by removing all non-digit characters.
 * Used for comparing phone numbers in different formats.
 */
export function normalizePhone(phone: string): string {
  if (!phone) return ''
  return phone.replace(/\D/g, '')
}

/**
 * Compare two phone numbers accounting for trunk prefix differences.
 * e.g. "370063949836" (with trunk 0) matches "37063949836" (without trunk 0)
 * by comparing the last 8 digits.
 */
export function phonesMatch(phone1: string, phone2: string): boolean {
  const n1 = normalizePhone(phone1)
  const n2 = normalizePhone(phone2)
  if (n1 === n2) return true
  if (n1.length >= 8 && n2.length >= 8) {
    return n1.slice(-8) === n2.slice(-8)
  }
  return false
}

/**
 * Validate phone number is E.164-like format (7-15 digits starting with non-zero).
 * Accepts with or without + prefix.
 */
export function isValidE164(phone: string): boolean {
  return /^\+?[1-9]\d{6,14}$/.test(phone)
}

/**
 * Generate plausible phone number variants for retry when Meta's
 * sandbox rejects a number with error #131030 ("not in allowed list").
 *
 * Many countries use a "trunk prefix" 0 for domestic dialing that is
 * meant to be dropped in international format (e.g. Lithuanian
 * "+370 063 949 836" domestically → "+370 63 949 836" international).
 * But some sandboxes register the number with the trunk 0 included,
 * causing sends to the correct international format to fail.
 *
 * This helper yields up to 3 variants:
 *   1. The original sanitized number (first attempt)
 *   2. With a trunk 0 inserted after the country code
 *   3. With a trunk 0 removed after the country code
 *
 * Country-code lengths of 1, 2, and 3 digits are tried because we
 * don't know the user's country ahead of time.
 *
 * @param sanitized - digits-only phone number (from sanitizePhoneForMeta)
 * @returns deduplicated list of variants, original first
 */
export function phoneVariants(sanitized: string): string[] {
  if (!sanitized) return []
  const seen = new Set<string>()
  const push = (v: string) => {
    if (v && !seen.has(v)) seen.add(v)
  }

  // 1. Original
  push(sanitized)

  // 2. Insert a 0 after each plausible country-code length
  for (const ccLen of [1, 2, 3]) {
    if (sanitized.length <= ccLen) continue
    const cc = sanitized.slice(0, ccLen)
    const rest = sanitized.slice(ccLen)
    if (!rest.startsWith('0')) {
      push(cc + '0' + rest)
    }
  }

  // 3. Remove a leading 0 after each plausible country-code length
  for (const ccLen of [1, 2, 3]) {
    if (sanitized.length <= ccLen + 1) continue
    const cc = sanitized.slice(0, ccLen)
    const rest = sanitized.slice(ccLen)
    if (rest.startsWith('0')) {
      push(cc + rest.slice(1))
    }
  }

  // 4. Trunk digits that are not 0, for the countries that use one.
  //
  // Mexico (+52) and Argentina (+54) sit a mobile trunk digit between the
  // country code and a 10-digit subscriber number — 1 and 9 respectively.
  // The WhatsApp webhook reports the number WITH it (+52 1 962 289 6918)
  // while Meta's allowed list usually holds it WITHOUT (+52 962 289 6918),
  // or the reverse, so both directions are worth an attempt.
  //
  // Deliberately scoped to those two country codes, and to the exact
  // subscriber length. Elsewhere 1 and 9 are ordinary first digits, so
  // stripping one blindly would build a different person's real number —
  // and in a sandbox that number could itself be on the allowed list,
  // turning a failed send into a send to the wrong person. A message that
  // does not arrive is recoverable; one that reaches a stranger is not.
  for (const [cc, trunk] of [['52', '1'], ['54', '9']] as const) {
    if (!sanitized.startsWith(cc)) continue
    const rest = sanitized.slice(cc.length)
    if (rest.startsWith(trunk) && rest.length === 11) {
      push(cc + rest.slice(1))
    } else if (!rest.startsWith(trunk) && rest.length === 10) {
      push(cc + trunk + rest)
    }
  }

  return [...seen]
}

/**
 * Returns true when the Meta API error indicates the recipient
 * phone number isn't in the allowed list (sandbox restriction).
 * Detected via error code 131030 or the standard error text.
 */
export function isRecipientNotAllowedError(message: string): boolean {
  return /131030|not in allowed list|not in the allowed list/i.test(message)
}

/**
 * Phone number as a person should read it.
 *
 * Numbers are stored E.164-like but bare — "529622896918" — and the
 * contacts table printed exactly that: a twelve-digit run with no
 * country marker and no grouping, which reads as an id, not a phone.
 *
 * Grouping rules are per-country and this app carries no phone-number
 * library, so guessing where the breaks go would invent structure that
 * may be wrong. The honest improvement is the marker: a leading "+" so
 * the string reads as an international number. Anything already
 * punctuated is left exactly as the user typed it.
 */
export function formatPhoneForDisplay(phone: string | null | undefined): string {
  const raw = (phone ?? '').trim()
  if (!raw) return ''
  return /^\d{7,15}$/.test(raw) ? `+${raw}` : raw
}
