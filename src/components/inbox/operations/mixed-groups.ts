import { formatNumber } from "@/lib/format-number";
import { effectiveStatus } from "@/lib/remittance-operations/effective-status";
import { currentServiceOf } from "@/lib/remittance-operations/services";
import type {
  MatchedDeposit,
  OperationReceiptsRead,
  PlannedSplitRead,
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

const PLANNED_GROUP_PREFIX = "planned:";

/** Whether `groupId` is the panel's own group for a split planned before the deposit (it is not a database group). */
export function isPlannedGroupId(groupId: string | null | undefined): boolean {
  return typeof groupId === "string" && groupId.startsWith(PLANNED_GROUP_PREFIX);
}

/** A split planned before the deposit (migrations 277, 369, 370) is not grouped in the database until its deposit arrives, but it
 *  is one send to the customer. Gives the open, ungrouped, unfunded operations of the plan's parts one panel-only group id so they
 *  render as one mixed send (parts and total) waiting for the deposit. One operation per part (the first of the list), at least two
 *  parts matched; anything else is returned untouched. A part whose operation has no amount yet shows the plan's amount. */
export function withPlannedSplit(
  operations: RemittanceOperationRead[],
  plan: PlannedSplitRead | null | undefined,
  conversationId: string,
): RemittanceOperationRead[] {
  if (!plan || plan.parts.length < 2) return operations;
  const matched = new Map<string, RemittanceOperationRead>();
  for (const part of plan.parts) {
    const found = operations.find(
      (operation) =>
        !operation.isHistory &&
        !operation.mixedGroupId &&
        (operation.status === "collecting_information" || operation.status === "awaiting_deposit") &&
        currentServiceOf(operation) === part.service &&
        ![...matched.values()].includes(operation),
    );
    if (found) matched.set(part.service, found);
  }
  if (matched.size < 2) return operations;
  const groupId = `${PLANNED_GROUP_PREFIX}${conversationId}`;
  const amounts = new Map(plan.parts.map((part) => [part.service, part.amountGyd]));
  const byOperation = new Map([...matched].map(([service, operation]) => [operation.id, service]));
  return operations.map((operation) => {
    const service = byOperation.get(operation.id);
    if (service === undefined) return operation;
    const own = operation.quotedSourceAmount ?? 0;
    return { ...operation, mixedGroupId: groupId, quotedSourceAmount: own > 0 ? own : (amounts.get(service) ?? own) };
  });
}
