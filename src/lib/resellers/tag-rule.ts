// ============================================================
// Reseller tag rule — the panel mirror of the SQL helper
// `public.reseller_tag_name_matches(text)` from migration 395.
//
// The database is the authority: 395 decides identity from the tag and
// 396 refuses an agent's add/remove of the reseller tag. This module is
// UI gating only, so the panel can disable the chip and explain why
// before the round-trip.
// ============================================================

/** Canonical display name of the reseller tag created by 395. */
export const RESELLER_TAG_NAME = "Revendedor";

/** HINT the 396 guard attaches to its SQLSTATE 42501 refusal. */
export const RESELLER_TAG_ADMIN_ONLY_HINT = "reseller_tag_admin_only";

/**
 * True iff `name` is the reseller tag after trimming surrounding spaces
 * and ignoring case. Mirrors `lower(btrim(p_name)) = 'revendedor'`:
 * no plural, no accent and no extra-text variants.
 */
export function isResellerTagName(name: string | null | undefined): boolean {
  return typeof name === "string" && name.trim().toLowerCase() === RESELLER_TAG_NAME.toLowerCase();
}

/** Shape of the Supabase/PostgREST error the panel can inspect. */
export interface PostgrestLikeError {
  code?: string | null;
  message?: string | null;
  hint?: string | null;
}

/**
 * True iff the error is the 396 guard refusing the current user. The
 * database is the authority, but a stale role in the client means the
 * request can still be refused; the panel must show a readable message
 * instead of a generic error.
 */
export function isResellerTagRefusal(
  error: PostgrestLikeError | null | undefined,
): boolean {
  if (!error || error.code !== "42501") return false;
  if (error.hint === RESELLER_TAG_ADMIN_ONLY_HINT) return true;
  return /revendedor/i.test(error.message ?? "");
}
