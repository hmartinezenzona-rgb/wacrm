/** Read model for the funding case panel (migration 332). The API returns
 *  the case with its verified / assigned / available GYD, the linked
 *  deposits and the allocations; `case` is null when the conversation has
 *  no case yet. */
export type FundingCaseStatus = "open" | "allocating" | "incident" | "closed";

export interface FundingCaseDepositRead {
  trans_id: string;
  monto: number;
  recibido_en: string | null;
  anulado_en: string | null;
}

export interface FundingCaseAllocationRead {
  id: string;
  operation_id: string;
  service: string | null;
  amount_gyd: number;
  status: string;
  evidence_type: string;
  created_at: string;
}

export interface FundingCaseOperationRead {
  id: string;
  service: string | null;
  status: string;
  quoted_source_amount: number;
  allocated: number;
}

export interface FundingCaseRead {
  id: string;
  status: FundingCaseStatus;
  opened_at: string;
  closed_at: string | null;
  note: string | null;
  depositado: number;
  asignado: number;
  disponible: number;
  deposits: FundingCaseDepositRead[];
  allocations: FundingCaseAllocationRead[];
  operations: FundingCaseOperationRead[];
}

export interface FundingCasePanelRead {
  case: FundingCaseRead | null;
}

/** The resolver returns the reconciliation result; only `status` is used
 *  by the panel, but the rest is kept for logging/debugging. */
export interface FundingCaseResolveRead {
  case_id: string | null;
  status: string;
  depositado: number;
  asignado: number;
  disponible: number;
  pending: string | null;
  conflict: string | null;
}
