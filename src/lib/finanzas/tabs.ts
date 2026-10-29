/** The tabs of the Finanzas section, in reading order. The old Operaciones tab is gone: its history search lives in Cierres. The URL carries the active one as `?tab=`. */
export const FINANZAS_TABS = ["semana", "cierres"] as const;

export type FinanzasTab = (typeof FINANZAS_TABS)[number];

/** A missing, repeated or unknown `?tab=` value means the first tab. */
export function parseFinanzasTab(value: string | string[] | undefined): FinanzasTab {
  return FINANZAS_TABS.find((tab) => tab === value) ?? "semana";
}
