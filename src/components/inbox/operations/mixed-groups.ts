import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

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

export interface OperationBlock {
  /** True when `members` are two or more operations of one mixed send, so the panel puts a header over them. */
  grouped: boolean;
  /** The open operations to render as cards, in panel order. */
  operations: RemittanceOperationRead[];
  /** Every operation of the group (history included), for the header and the split editor. */
  members: RemittanceOperationRead[];
}

/** Arranges the open operations for display: a group's open members sit together at the place of its first member,
 *  every other operation stays a block of its own. `all` is every operation of the conversation, history included. */
export function groupOpenOperations(
  open: RemittanceOperationRead[],
  all: RemittanceOperationRead[],
): OperationBlock[] {
  const blocks: OperationBlock[] = [];
  const blockByGroup = new Map<string, OperationBlock>();
  for (const operation of open) {
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
