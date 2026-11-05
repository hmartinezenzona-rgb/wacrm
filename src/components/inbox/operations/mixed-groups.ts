import { formatNumber } from "@/lib/format-number";
import { effectiveStatus } from "@/lib/remittance-operations/effective-status";
import type {
  MatchedDeposit,
  OperationReceiptsRead,
  RemittanceOperationRead,
} from "@/lib/remittance-operations/types";

/** The operations that share `operation`'s deposit (migration 253), history included because a completed member still
 *  holds part of the group's total; the operation alone when it is not grouped or its group shows no other member. */
export function mixedGroupMembers(
  operation: RemittanceOperationRead,
  operations: RemittanceOperationRead[],
): RemittanceOperationRead[] {
  if (!operation.mixedGroupId) return [operation];
  const members = operations.filter((candidate) => candidate.mixedGroupId === operation.mixedGroupId);
  return members.length >= 2 ? members : [operation];
}

/** The deposit the group shares: the sum of its members' quoted GYD. */
export function mixedGroupTotal(members: RemittanceOperationRead[]): number {
  return members.reduce((sum, member) => sum + (member.quotedSourceAmount ?? 0), 0);
}

/** The destination amount and currency delivered for this share, or null when absent or in GYD. */
export function mixedShareDestination(member: RemittanceOperationRead): string | null {
  if (
    typeof member.quotedDestinationAmount === "number" &&
    member.destinationCurrency &&
    member.destinationCurrency !== "GYD"
  ) {
    return `${formatNumber(member.quotedDestinationAmount)} ${member.destinationCurrency}`;
  }
  return null;
}

export interface OperationBlock {
  /** True when `members` are two or more operations of one mixed send, so the panel puts a header over them. */
  grouped: boolean;
  /** The operations to render as cards, in panel order. */
  operations: RemittanceOperationRead[];
  /** Every operation of the group visible in `all`, for the header and the split editor. */
  members: RemittanceOperationRead[];
}

/** Arranges `list` for display: a group's members in `list` sit together at the place of its first member, every
 *  other operation stays a block of its own. `all` is where the group's members are looked up: every operation of the
 *  conversation for the open list (history included), the history list itself for the history section. */
export function groupOperations(
  list: RemittanceOperationRead[],
  all: RemittanceOperationRead[],
): OperationBlock[] {
  const blocks: OperationBlock[] = [];
  const blockByGroup = new Map<string, OperationBlock>();
  for (const operation of list) {
    const members = mixedGroupMembers(operation, all);
    if (members.length < 2) {
      blocks.push({ grouped: false, operations: [operation], members });
      continue;
    }
    const existing = blockByGroup.get(operation.mixedGroupId!);
    if (existing) {
      existing.operations.push(operation);
      continue;
    }
    const block: OperationBlock = { grouped: true, operations: [operation], members };
    blockByGroup.set(operation.mixedGroupId!, block);
    blocks.push(block);
  }
  return blocks;
}

/** The open operations arranged for display (`all` is every operation of the conversation, history included). */
export const groupOpenOperations = groupOperations;

/** The first `limit` blocks: a group counts as one entry, so it is never cut in half. `hiddenOperations` counts the
 *  operations of the blocks left out. */
export function limitBlocks(
  blocks: OperationBlock[],
  limit: number,
): { visible: OperationBlock[]; hiddenOperations: number } {
  const visible = blocks.slice(0, limit);
  const hiddenOperations = blocks.slice(limit).reduce((sum, block) => sum + block.operations.length, 0);
  return { visible, hiddenOperations };
}

export interface CompletableGroup {
  /** The one consumed, unvoided deposit that pays the whole send. */
  deposit: MatchedDeposit;
}

/** Whether a mixed send can be completed from one "Completar envio": two or more members, every one ready to transfer
 *  (history and cancelled members never count), and exactly ONE distinct consumed unvoided deposit among the members'
 *  receipts (the deposit sits on one member's deal; the others list none). A member whose receipts are unknown makes
 *  the answer null: the per-part buttons stay, so nothing is assumed. An admin's forced verification is not part of
 *  the panel's data, so a forced group keeps the per-part buttons. */
export function completableGroup(
  members: RemittanceOperationRead[],
  receiptsByOperationId: Record<string, OperationReceiptsRead> | undefined,
): CompletableGroup | null {
  if (members.length < 2 || !receiptsByOperationId) return null;
  const deposits = new Map<string, MatchedDeposit>();
  for (const member of members) {
    if (member.isHistory || effectiveStatus(member) !== "ready_to_transfer") return null;
    const receipts = receiptsByOperationId[member.id];
    if (!receipts) return null;
    for (const deposit of receipts.consumedDeposits) deposits.set(deposit.transId, deposit);
  }
  if (deposits.size !== 1) return null;
  return { deposit: [...deposits.values()][0]! };
}
