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
