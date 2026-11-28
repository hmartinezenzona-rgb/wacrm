// Pure model of the read-only operations board (/tablero): which column an
// operation lands in, the service filter, the missing-recipient hint and the
// "time in this state" figure. No React, no I/O.

export type BoardColumnId = "requested" | "depositCheck" | "readyToTransfer" | "incident" | "completed";

export interface BoardOperation {
  operationId: string;
  conversationId: string;
  contactName: string | null;
  contactPhone: string | null;
  serviceType: string;
  deliveryMethod: string | null;
  status: string;
  quotedSourceAmount: number | null;
  sourceCurrency: string | null;
  createdAt: string;
  completedAt: string | null;
  /** When the operation entered its current status (see migration 214). */
  stateSince: string;
  beneficiariesComplete: boolean | null;
}

export const BOARD_COLUMNS: ReadonlyArray<{ id: BoardColumnId; statuses: ReadonlyArray<string> }> = [
  // awaiting_deposit and deposit_received have no column of their own: they sit with the step they are closest to, so an
  // operation in either one does not vanish from the board.
  { id: "requested", statuses: ["collecting_information", "awaiting_deposit"] },
  { id: "depositCheck", statuses: ["deposit_verification", "deposit_received"] },
  { id: "readyToTransfer", statuses: ["ready_to_transfer", "transferring"] },
  { id: "completed", statuses: ["completed"] },
  // Last on purpose (owner, 2026-10-06): the normal flow reads left to right, exceptions at the end.
  { id: "incident", statuses: ["incident"] },
];

export const SERVICE_FILTERS = ["all", "remesa", "recarga", "combo", "visa", "saldo"] as const;
export type ServiceFilter = (typeof SERVICE_FILTERS)[number];

export interface BoardColumn {
  id: BoardColumnId;
  items: BoardOperation[];
  count: number;
}

/** Groups operations into the board's columns, keeping the input order (the
 *  RPC already sorts by column, then by time in state). Statuses the board
 *  does not show (e.g. cancelled) are dropped. */
export function groupBoard(operations: ReadonlyArray<BoardOperation>, filter: ServiceFilter): BoardColumn[] {
  const visible = filter === "all" ? operations : operations.filter((o) => o.serviceType === filter);
  return BOARD_COLUMNS.map(({ id, statuses }) => {
    const items = visible.filter((o) => statuses.includes(o.status));
    return { id, items, count: items.length };
  });
}

/** A visa needs no recipients; a completed operation is past caring. */
export function showMissingBeneficiaries(op: BoardOperation): boolean {
  return op.beneficiariesComplete === false && op.serviceType !== "visa" && op.status !== "completed";
}

export type AgeUnit = "lessThanMinute" | "minutes" | "hours" | "days";

export function ageParts(since: string, now: Date): { unit: AgeUnit; value: number } {
  const ms = Math.max(0, now.getTime() - new Date(since).getTime());
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return { unit: "lessThanMinute", value: 0 };
  if (minutes < 60) return { unit: "minutes", value: minutes };
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return { unit: "hours", value: hours };
  return { unit: "days", value: Math.floor(hours / 24) };
}

/** Hours in a status from which the age text asks for attention, and from which it warns. */
export const AGE_ATTENTION_HOURS = 2;
export const AGE_DANGER_HOURS = 24;

export type AgeTone = "muted" | "attention" | "danger";

/**
 * Tone of the "time in this status" text: muted while recent, attention from `AGE_ATTENTION_HOURS`, danger from
 * `AGE_DANGER_HOURS`. A completed operation is past waiting, so it never escalates. The text itself ("3 h", "2 d")
 * carries the figure, so colour is never the only cue.
 */
export function ageTone(since: string, now: Date, status: string): AgeTone {
  if (status === "completed") return "muted";
  const hours = (now.getTime() - new Date(since).getTime()) / 3_600_000;
  if (hours >= AGE_DANGER_HOURS) return "danger";
  if (hours >= AGE_ATTENTION_HOURS) return "attention";
  return "muted";
}

/** The inbox link; the id travels in sessionStorage (see setInboxOpenTarget). */
export function chatHref(_conversationId: string): string {
  return "/inbox";
}

/** Maximum rows of the "Atrasadas" strip. */
export const LATE_STRIP_MAX = 5;

/**
 * The stalest in-flight operations: the ones at the most severe age tone, oldest first, at most `max`. Only statuses the
 * board shows count, and a completed operation never does (it is past waiting). Pure: the input is not reordered.
 */
export function lateOperations(operations: ReadonlyArray<BoardOperation>, now: Date, max = LATE_STRIP_MAX): BoardOperation[] {
  const inFlight = new Set(BOARD_COLUMNS.flatMap((c) => c.statuses).filter((s) => s !== "completed"));
  return operations
    .filter((o) => inFlight.has(o.status) && ageTone(o.stateSince, now, o.status) === "danger")
    .sort((a, b) => new Date(a.stateSince).getTime() - new Date(b.stateSince).getTime())
    .slice(0, max);
}
