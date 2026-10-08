/**
 * Status tones — the fixed colour of an operation status shown as a pill.
 *
 *   neutral    not started / gathering data     info       in progress, waiting on the customer
 *   attention  waiting on US: the team acts now  success    completed
 *   danger     incident
 *
 * The colours live in globals.css as --status-* tokens, independent of the accent theme. The pill always carries
 * the translated status label, so colour is never the only cue. Class names are written out in full for Tailwind.
 */

export type StatusTone = "neutral" | "info" | "attention" | "success" | "danger";

/** Every status an operation can be shown with: the DB values plus the panel's synthetic `awaiting_beneficiary`. */
const TONE_BY_STATUS = {
  collecting_information: "neutral",
  awaiting_deposit: "info",
  deposit_received: "attention",
  deposit_verification: "attention",
  ready_to_transfer: "attention",
  transferring: "info",
  incident: "danger",
  completed: "success",
  awaiting_beneficiary: "info",
} as const satisfies Record<string, StatusTone>;

export const OPERATION_STATUSES = Object.keys(TONE_BY_STATUS) as ReadonlyArray<keyof typeof TONE_BY_STATUS>;

/** Tone of a status; an unknown, empty or missing value is neutral. */
export function statusTone(status: string | null | undefined): StatusTone {
  if (status && Object.prototype.hasOwnProperty.call(TONE_BY_STATUS, status)) {
    return TONE_BY_STATUS[status as keyof typeof TONE_BY_STATUS];
  }
  return "neutral";
}

/** Soft tinted background plus tone text of the pill. Neutral uses the theme's muted pair. */
export const statusPillClass: Record<StatusTone, string> = {
  neutral: "bg-muted text-muted-foreground",
  info: "bg-status-info-soft text-status-info",
  attention: "bg-status-attention-soft text-status-attention",
  success: "bg-status-success-soft text-status-success",
  danger: "bg-status-danger-soft text-status-danger",
};
