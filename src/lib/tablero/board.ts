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
  { id: "requested", statuses: ["collecting_information"] },
  { id: "depositCheck", statuses: ["deposit_verification"] },
  { id: "readyToTransfer", statuses: ["ready_to_transfer", "transferring"] },
  { id: "incident", statuses: ["incident"] },
  { id: "completed", statuses: ["completed"] },
];

export const SERVICE_FILTERS = ["all", "remesa", "recarga", "combo", "visa"] as const;
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

/** The same deep link the notifications page uses to open a chat. */
export function chatHref(conversationId: string): string {
  return `/inbox?c=${conversationId}`;
}
