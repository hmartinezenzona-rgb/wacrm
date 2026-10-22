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
}

export type MexicoBeneficiaryType = (typeof MEXICO_BENEFICIARY_TYPES)[number];

/** The message key of the reason a draft is refused (keys of `Inbox.operationsPanel`). */
export type MexicoDraftError = "cannotBeEmpty" | "invalidClabe" | "invalidPhone";

const PHONE_PATTERN = /^\d{8,15}$/;
const CLABE_PATTERN = /^\d{18}$/;

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

  if (type === "mexico_cuenta") {
    const clabe = draft.clabe.replace(/\D/g, "");
    if (!CLABE_PATTERN.test(clabe)) return { ok: false, error: "invalidClabe" };
    const bankName = draft.bankName.trim();
    if (bankName === "") return { ok: false, error: "cannotBeEmpty" };
    return { ok: true, datos: { beneficiary_type: type, name, clabe, bank_name: bankName } };
  }

  const bankName = draft.bankName.trim();
  if (!(MEXICO_WITHDRAWAL_BANKS as readonly string[]).includes(bankName)) return { ok: false, error: "cannotBeEmpty" };
  const phone = draft.phone.replace(/\D/g, "");
  if (!PHONE_PATTERN.test(phone)) return { ok: false, error: "invalidPhone" };
  return { ok: true, datos: { beneficiary_type: type, name, bank_name: bankName, phone } };
}
