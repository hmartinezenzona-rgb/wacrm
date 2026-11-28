// México recipients (service_type mexico): a bank account (`mexico_cuenta`, CLABE + bank + holder) or a cardless
// withdrawal (`mexico_retiro`, Coppel or BBVA + receiver + phone). The database names the types and columns; this
// module only shapes what the panel shows and sends.

export const MEXICO_BENEFICIARY_TYPES = ["mexico_cuenta", "mexico_retiro"] as const;

/** The networks a cardless withdrawal can be picked up at (stored in `bank_name`). Brand names, not translated. */
export const MEXICO_WITHDRAWAL_BANKS = ["Coppel", "BBVA"] as const;

export function isMexicoBeneficiaryType(type: string | null | undefined): boolean {
  return (MEXICO_BENEFICIARY_TYPES as readonly string[]).includes(type ?? "");
}

/** A CLABE for reading: 18 digits grouped 4-4-4-6. Anything that is not 18 digits is returned as it is. */
export function formatClabe(clabe: string): string {
  if (!/^\d{18}$/.test(clabe)) return clabe;
  return `${clabe.slice(0, 4)} ${clabe.slice(4, 8)} ${clabe.slice(8, 12)} ${clabe.slice(12)}`;
}

/** What the add form holds for a México recipient, before it is checked. */
export interface MexicoRecipientDraft {
  name: string;
  clabe: string;
  bankName: string;
  phone: string;
  /** The USD that goes to this recipient, as typed; empty when one recipient takes the whole send (290). */
  amount?: string;
}

export type MexicoBeneficiaryType = (typeof MEXICO_BENEFICIARY_TYPES)[number];

/** The message key of the reason a draft is refused (keys of `Inbox.operationsPanel`). */
export type MexicoDraftError = "cannotBeEmpty" | "invalidClabe" | "invalidPhone" | "invalidAmount";

const PHONE_PATTERN = /^\d{8,15}$/;
const CLABE_PATTERN = /^\d{18}$/;

/** The typed USD amount: `null` when empty, `NaN`-free number when valid, `"invalid"` for zero, negative or non-numeric. */
function parseAmount(typed: string | undefined): number | null | "invalid" {
  const trimmed = (typed ?? "").trim();
  if (trimmed === "") return null;
  const value = Number(trimmed);
  return Number.isFinite(value) && value > 0 ? value : "invalid";
}

/**
 * Checks a México recipient draft and shapes the `datos` that `crm_agregar_beneficiario` takes (snake_case keys). A
 * CLABE may be typed with spaces; only its digits are kept. Returns the first problem found, never a partial payload.
 */
export function buildMexicoBeneficiaryDatos(
  type: MexicoBeneficiaryType,
  draft: MexicoRecipientDraft,
): { ok: true; datos: Record<string, unknown> } | { ok: false; error: MexicoDraftError } {
  const name = draft.name.trim();
  if (name === "") return { ok: false, error: "cannotBeEmpty" };
  const amount = parseAmount(draft.amount);
  if (amount === "invalid") return { ok: false, error: "invalidAmount" };
  const withAmount = amount === null ? {} : { amount };

  if (type === "mexico_cuenta") {
    const clabe = draft.clabe.replace(/\D/g, "");
    if (!CLABE_PATTERN.test(clabe)) return { ok: false, error: "invalidClabe" };
    const bankName = draft.bankName.trim();
    if (bankName === "") return { ok: false, error: "cannotBeEmpty" };
    return { ok: true, datos: { beneficiary_type: type, name, clabe, bank_name: bankName, ...withAmount } };
  }

  const bankName = draft.bankName.trim();
  if (!(MEXICO_WITHDRAWAL_BANKS as readonly string[]).includes(bankName)) return { ok: false, error: "cannotBeEmpty" };
  const phone = draft.phone.replace(/\D/g, "");
  if (!PHONE_PATTERN.test(phone)) return { ok: false, error: "invalidPhone" };
  return { ok: true, datos: { beneficiary_type: type, name, bank_name: bankName, phone, ...withAmount } };
}

/** The stored México fields of a recipient, as the inline editor reads them. */
export interface MexicoRecipientCurrent {
  beneficiaryType: string;
  name: string | null;
  clabe?: string | null;
  bankName?: string | null;
  phone: string | null;
  /** The USD that goes to this recipient, when set (290). */
  amount?: number | null;
}

/**
 * Checks an inline edit of a México recipient and returns only the keys that changed, in the snake_case form
 * `crm_corregir_beneficiario` takes. A bank account never changes its phone here; a withdrawal's network must stay
 * Coppel or BBVA.
 */
export function buildMexicoBeneficiaryChanges(
  current: MexicoRecipientCurrent,
  draft: MexicoRecipientDraft,
): { ok: true; changes: Record<string, string | number | null> } | { ok: false; error: MexicoDraftError } {
  const name = draft.name.trim();
  if (name === "") return { ok: false, error: "cannotBeEmpty" };
  const changes: Record<string, string | number | null> = {};
  if (name !== (current.name ?? "")) changes.name = name;
  const amount = parseAmount(draft.amount);
  if (amount === "invalid") return { ok: false, error: "invalidAmount" };
  if (draft.amount !== undefined && amount !== (current.amount ?? null)) changes.amount = amount;

  const bankName = draft.bankName.trim();
  if (current.beneficiaryType === "mexico_cuenta") {
    const clabe = draft.clabe.replace(/\D/g, "");
    if (!CLABE_PATTERN.test(clabe)) return { ok: false, error: "invalidClabe" };
    if (bankName === "") return { ok: false, error: "cannotBeEmpty" };
    if (clabe !== (current.clabe ?? "")) changes.clabe = clabe;
    if (bankName !== (current.bankName ?? "")) changes.bank_name = bankName;
    return { ok: true, changes };
  }

  if (!(MEXICO_WITHDRAWAL_BANKS as readonly string[]).includes(bankName)) return { ok: false, error: "cannotBeEmpty" };
  const phone = draft.phone.replace(/\D/g, "");
  if (!PHONE_PATTERN.test(phone)) return { ok: false, error: "invalidPhone" };
  if (bankName !== (current.bankName ?? "")) changes.bank_name = bankName;
  if (phone !== (current.phone ?? "")) changes.phone = phone;
  return { ok: true, changes };
}
