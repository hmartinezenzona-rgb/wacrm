// Maps the panel's effective status to the 4-step progress line shown in an open operation's card header:
// 1 collecting data, 2 deposit, 3 transfer, 4 done. Pure, no I/O.

import type { EffectiveStatus } from "./effective-status";

export const PROGRESS_STEPS = 4;

const STEP_BY_STATUS: Record<EffectiveStatus, 1 | 2 | 3 | 4> = {
  collecting_information: 1,
  awaiting_deposit: 2,
  deposit_received: 2,
  deposit_verification: 2,
  incident: 2,
  ready_to_transfer: 3,
  transferring: 3,
  awaiting_beneficiary: 3,
  completed: 4,
};

export function progressStep(status: EffectiveStatus): 1 | 2 | 3 | 4 {
  return STEP_BY_STATUS[status];
}
