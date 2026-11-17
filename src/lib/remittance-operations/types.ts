// ============================================================
// Read-only typed view of the in-chat remesa operations panel's data
// source: the `crm_operaciones_de_conversacion` SECURITY DEFINER RPC
// (migration 097). Slice 5 is read-only — corrections, reassignment,
// deposit review and delivery actions are later slices (design decisions
// 1, 11, 12; spec capabilities admin-field-ownership /
// deposit-verification-review / remesa-delivery are NOT implemented here).
// ============================================================

/**
 * Resolver state for "which operation(s) is this conversation about right
 * now" — mirrors `cerebro_resolver_operacion` (migration 040) verbatim:
 *   - "unica"   exactly one non-terminal operation for the conversation
 *   - "ninguna" no non-terminal operation
 *   - "ambigua" two or more non-terminal operations — the panel MUST NOT
 *     guess which one to show (spec: chat-remesa-operations-panel,
 *     "Resolver State Handling").
 *
 * NOTE: this resolver state is computed over ALL non-terminal operations
 * of the conversation regardless of `service_type` (migration 097 reuses
 * the resolver's exact semantics unfiltered, per design). The `operations`
 * list below is filtered to `service_type = 'remesa'` only (spec: REMESAS
 * only in this change). In practice every operation is `service_type =
 * 'remesa'` today (migration 046), so the two views agree; if a non-remesa
 * operation is ever live in the same conversation, the resolver state can
 * disagree with the (remesa-only) operations list — e.g. "ambigua" from a
 * remesa + a combo, while `operations` shows only the one remesa. This is
 * a documented, accepted deviation, not a bug — see migration 097's file
 * header.
 */
export type ResolverState = "unica" | "ninguna" | "ambigua";

/** `remittance_operations.status`. The RPC never returns `cancelled` rows;
 *  `completed` is returned only for history rows (migration 102) — see
 *  `operation_is_history` on `RemittanceOperationsRpcRow`. */
export type RemittanceOperationStatus =
  | "collecting_information"
  | "awaiting_deposit"
  | "deposit_received"
  | "deposit_verification"
  | "ready_to_transfer"
  | "transferring"
  | "incident"
  | "completed";

/** `remittance_operations.delivery_mode` (migrations 101/102) — how a
 *  completed operation's delivery proof was handled. `legacy_pipeline`
 *  covers operations completed before the delivery RPC existed (the old
 *  Kanban drag-to-Entregada path), which never set this column.
 *  `closed_manually` (migration 190) is an owner/admin close that skips the
 *  delivery and never notifies the customer. */
export type OperationDeliveryMode =
  | "proof_sent"
  | "no_proof"
  | "skip_proof"
  | "legacy_pipeline"
  | "closed_manually";

/** `remittance_beneficiaries.beneficiary_type` (migration 042). */
export type BeneficiaryType =
  | "cuban_card"
  | "zelle"
  | "clasica"
  | "tropical"
  | "efectivo_usd"
  | "multiple_distribution"
  /** One Cuban mobile number per recharge (migration 198); the number is in `phone`. */
  | "recarga"
  /** One food-combo recipient (migration 208): name, phone, address, reference,
   *  contact phone and an amount in GYD. */
  | "combo"
  /** México bank-account recipient: holder in `name`, 18-digit `clabe`, `bank_name`. */
  | "mexico_cuenta"
  /** México cardless withdrawal recipient: receiver in `name`, `phone`, `bank_name` = Coppel or BBVA. */
  | "mexico_retiro";

/** Whether a quoted destination amount / beneficiary amount was
 *  auto-calculated (single-beneficiary remittances, migration 100) or set
 *  by hand. */
export type AmountOrigin = "calculated" | "manual";

export interface AdminLockedFieldEntry {
  by: string | null;
  at: string;
}

/** `remittance_operations.admin_locked_fields` (migration 096) — read-only
 *  here; the panel only needs it so a later (Slice 6) correction UI can
 *  render a field as already-locked. Nothing in Slice 5 writes to it. */
export type AdminLockedFields = Record<string, AdminLockedFieldEntry>;

export interface RemittanceBeneficiaryRead {
  id: string;
  beneficiaryType: BeneficiaryType;
  name: string | null;
  /** Full (unmasked) card number, shown so operators can copy it — the
   *  same value already appears in the conversation thread on this
   *  screen, so masking it here bought no privacy. */
  cardNumber: string | null;
  /** Full (unmasked) phone number, shown so operators can copy it — same
   *  rationale as `cardNumber`. */
  phone: string | null;
  zelleAccount: string | null;
  deliveryMethod: string | null;
  amount: number | null;
  /** Whether `amount` was auto-calculated or set manually (migration 100);
   *  `null` when the beneficiary predates that column. */
  amountOrigin: AmountOrigin | null;
  currency: string | null;
  position: number;
  /** Cash recipient's delivery address (`efectivo_usd`, migration 189). */
  address: string | null;
  /** Combo recipient's directions on how to get there (migration 208). */
  reference?: string | null;
  /** Combo recipient's second contact phone (migration 208). */
  contactPhone?: string | null;
  /** México bank-account recipient's 18-digit CLABE. */
  clabe?: string | null;
  /** México recipient's bank: the bank of a `mexico_cuenta`, or Coppel/BBVA for a `mexico_retiro`. */
  bankName?: string | null;
  /** WhatsApp message id of the recipient's ID-card photo. */
  idPhotoWamid: string | null;
  /** Media URL of that photo, when the message is in the conversation. */
  idPhotoUrl: string | null;
}

export interface RemittanceOperationRead {
  id: string;
  status: RemittanceOperationStatus;
  serviceType: string;
  sourceCurrency: string | null;
  destinationCurrency: string | null;
  deliveryMethod: string | null;
  depositMethod: string | null;
  quotedSourceAmount: number | null;
  quotedDestinationAmount: number | null;
  /** Exchange rate used to auto-calculate `quotedDestinationAmount`
   *  (migration 100); `null` when not calculated or not recorded. */
  quotedDestinationRate: number | null;
  /** Whether `quotedDestinationAmount` was auto-calculated or set
   *  manually; `null` when the operation predates that column. */
  quotedDestinationOrigin: AmountOrigin | null;
  adminLockedFields: AdminLockedFields;
  createdAt: string;
  completedAt: string | null;
  /** Whether this row is one of the (at most 10) read-only completed
   *  history rows the RPC appends after the open operations (migration
   *  102), rather than a live/open operation. */
  isHistory: boolean;
  /** `crm_beneficiarios_completos(operation_id)` (migration 102): every
   *  `vigente` beneficiary has the fields its type requires, and there is
   *  at least one. Drives `effectiveStatus` and the delivery gate. */
  beneficiariesComplete: boolean;
  /** How this operation's delivery proof was handled; `null` while the
   *  operation isn't completed yet. */
  deliveryMode: OperationDeliveryMode | null;
  /** When this operation was delivered; `null` for open operations. */
  deliveredAt: string | null;
  /** Combo operations only (migration 208): the total cost the admin entered, in
   *  GYD. `null` until entered. Absent on responses that predate the column. */
  comboCostoGyd?: number | null;
  /** Mixed send (migration 253): the id of the anchor operation of the group that shares one deposit, the same on
   *  every member. `null` when the operation is not grouped. Always set by the mapper; optional so fixtures need not. */
  mixedGroupId?: string | null;
  beneficiaries: RemittanceBeneficiaryRead[];
}

/** What the bot last quoted for the conversation (`crm_cotizacion_de_
 *  conversacion`, migration 187). Read-only context shown before any
 *  deposit; it never feeds an operation's amounts. The destination is read
 *  from the bot's text, so it can be absent. */
export interface ConversationQuoteRead {
  gyd: number;
  destinationAmount: number | null;
  destinationCurrency: "CUP" | "USD" | null;
  quotedAt: string;
}

/** Raw row of `crm_cotizacion_de_conversacion` (0 or 1 row). `numeric`
 *  columns may arrive as strings from PostgREST. */
export interface ConversationQuoteRpcRow {
  gyd: number | string;
  destino_monto: number | string | null;
  destino_moneda: string | null;
  cotizado_en: string;
}

/** A split planned before the deposit (migrations 277, 369, 370): the parts the customer listed and their total. */
export interface PlannedSplitRead {
  totalGyd: number;
  parts: { service: string; amountGyd: number }[];
}

/** Raw row of `crm_reparto_planeado_de_conversacion` (one per part). `numeric` columns may arrive as strings. */
export interface PlannedSplitRpcRow {
  servicio: string;
  monto_gyd: number | string;
  posicion: number;
  total_gyd: number | string;
}

export interface ConversationOperationsRead {
  resolverState: ResolverState;
  resolverOperationId: string | null;
  resolverCandidateCount: number;
  /** Open (non-terminal) `service_type = 'remesa'` operations only, each
   *  with its `status = 'vigente'` beneficiaries, newest first. Empty when
   *  `resolverState === "ninguna"` — the panel must never fabricate an
   *  operation (spec: "No open operation"). */
  operations: RemittanceOperationRead[];
  /**
   * Convenience prefetch (panel-26): each operation's `crm_comprobantes_
   * de_operacion` read, keyed by operation id, composed by the route
   * alongside `operations` so the deposit review block can paint in the
   * SAME round trip instead of waiting for its own follow-up fetch.
   * `mapRemittanceOperationsRows` itself never sets this field — it's pure
   * and only maps the operations RPC — so it's optional here and only the
   * route adds it.
   *
   * A missing entry for a given operation id is NORMAL, not an error: that
   * operation's receipts RPC call failed (logged, not fatal to the
   * request), or the map simply wasn't composed. The client MUST treat a
   * missing entry as "fetch it myself" (the existing receipts route),
   * never as "this operation has no receipts."
   */
  receiptsByOperationId?: Record<string, OperationReceiptsRead>;
  /** The bot's current quote for the conversation, composed by the route
   *  next to `operations`. `null` when there is none, or when its read
   *  failed (convenience data: never fatal to the request). Absent only
   *  on responses that predate this field. */
  quote?: ConversationQuoteRead | null;
  /** The conversation's split planned before the deposit, composed by the route (migration 370). `null` when there is
   *  none or its read failed (convenience data: never fatal). */
  plannedSplit?: PlannedSplitRead | null;
}

/**
 * Raw row shape returned by `crm_operaciones_de_conversacion` — one row
 * per (operation, beneficiary) pair, LEFT JOINed, so an operation with no
 * beneficiaries yields exactly one row with every `beneficiary_*` column
 * NULL, and a conversation with no live remesa yields exactly one row
 * with every `operation_*`/`beneficiary_*` column NULL (resolver columns
 * only). Never read directly outside `read-model.ts` — `card_number` and
 * `phone` here are RAW values from the database, passed through unmasked
 * into `RemittanceBeneficiaryRead` (product decision: operators need to
 * copy them, and they already appear in the conversation thread).
 */
export interface RemittanceOperationsRpcRow {
  resolver_resultado: ResolverState;
  resolver_operation_id: string | null;
  resolver_candidatas: number;
  operation_id: string | null;
  operation_status: RemittanceOperationStatus | null;
  operation_service_type: string | null;
  operation_source_currency: string | null;
  operation_destination_currency: string | null;
  operation_delivery_method: string | null;
  operation_deposit_method: string | null;
  operation_quoted_source_amount: number | string | null;
  operation_quoted_destination_amount: number | string | null;
  operation_quoted_destination_rate: number | string | null;
  operation_quoted_destination_origin: AmountOrigin | null;
  operation_admin_locked_fields: AdminLockedFields | null;
  operation_created_at: string | null;
  operation_completed_at: string | null;
  beneficiary_id: string | null;
  beneficiary_type: BeneficiaryType | null;
  beneficiary_name: string | null;
  beneficiary_card_number: string | null;
  beneficiary_phone: string | null;
  beneficiary_zelle_account: string | null;
  beneficiary_delivery_method: string | null;
  beneficiary_amount: number | string | null;
  beneficiary_amount_origin: AmountOrigin | null;
  beneficiary_currency: string | null;
  beneficiary_position: number | null;
  operation_is_history: boolean | null;
  operation_beneficiaries_complete: boolean | null;
  operation_delivery_mode: OperationDeliveryMode | null;
  operation_delivered_at: string | null;
  beneficiary_address: string | null;
  beneficiary_id_photo_wamid: string | null;
  beneficiary_id_photo_url: string | null;
  /** Migration 208 (combo); absent on responses that predate it. */
  beneficiary_reference?: string | null;
  /** México recipients (migration for mexico): absent on responses that predate the columns. */
  beneficiary_clabe?: string | null;
  beneficiary_bank_name?: string | null;
  beneficiary_contact_phone?: string | null;
  operation_combo_costo_gyd?: number | string | null;
  operation_mixed_group_id?: string | null;
}

// ============================================================
// Deposit review (migration 099) — `crm_comprobantes_de_operacion`,
// `crm_verificar_deposito`, `crm_forzar_verificacion`. Panels 14/15.
// ============================================================

export interface MatchedDeposit {
  transId: string;
  amount: number | null;
  currency: string | null;
  receivedAt: string | null;
  consumedAt: string | null;
}

export interface DepositReceipt {
  compId: string;
  messageId: string | null;
  mediaUrl: string | null;
  receivedAt: string | null;
  declaredAmount: number | null;
  declaredCurrency: string | null;
  declaredRef: string | null;
  matchedDeposit: MatchedDeposit | null;
}

export interface OperationReceiptsRead {
  operationId: string;
  status: string;
  dealId: string | null;
  canVerify: boolean;
  objetivo: number | null;
  depositado: number | null;
  saldo: number | null;
  moneda: string | null;
  receipts: DepositReceipt[];
  consumedDeposits: MatchedDeposit[];
}

/** Raw row shape nested inside `crm_comprobantes_de_operacion`'s
 *  `receipts[].matched_deposit` and `consumed_deposits[]`. */
export interface MatchedDepositRpcRow {
  trans_id: string;
  amount: number | string | null;
  currency: string | null;
  received_at: string | null;
  consumed_at: string | null;
}

/** Raw row shape inside `crm_comprobantes_de_operacion`'s `receipts[]`. */
export interface DepositReceiptRpcRow {
  comp_id: string;
  message_id: string | null;
  media_url: string | null;
  received_at: string | null;
  declared_amount: number | string | null;
  declared_currency: string | null;
  declared_ref: string | null;
  matched_deposit: MatchedDepositRpcRow | null;
}

/** Raw payload returned by `crm_comprobantes_de_operacion(p_operation_id)`.
 *  Never read directly outside `receipts-read-model.ts`. */
export interface OperationReceiptsRpcPayload {
  operation_id: string;
  status: string;
  deal_id: string | null;
  can_verify: boolean;
  objetivo: number | string | null;
  depositado: number | string | null;
  saldo: number | string | null;
  moneda: string | null;
  receipts: DepositReceiptRpcRow[] | null;
  consumed_deposits: MatchedDepositRpcRow[] | null;
}

/** One `{ref, amount}` line item sent to `crm_verificar_deposito`. */
export interface VerifyDepositItem {
  ref: string;
  amount: number;
}

export interface VerifyDepositResult {
  resultado: string;
  metodo: string | null;
  todosVerificados: boolean;
  totalVerificado: number | null;
  nComprobantes: number | null;
  detalle: unknown;
  objetivo: number | null;
  depositado: number | null;
  saldo: number | null;
  stageChanged: boolean;
  newStatus: string;
}

/** Raw payload returned by `crm_verificar_deposito(p_operation_id,
 *  p_items)`. Never read directly outside `receipts-read-model.ts`. */
export interface VerifyDepositRpcPayload {
  resultado: string;
  metodo: string | null;
  todos_verificados: boolean;
  total_verificado: number | string | null;
  n_comprobantes: number | string | null;
  detalle: unknown;
  objetivo: number | string | null;
  depositado: number | string | null;
  saldo: number | string | null;
  stage_changed: boolean;
  new_status: string;
}

/** One image message of a conversation the panel may offer as a cash recipient's ID photo
 *  (`crm_imagenes_de_conversacion`, migration 233). `wamid` is `messages.message_id`, the value stored in
 *  `remittance_beneficiaries.id_photo_wamid`. */
/** A MMG ledger deposit nobody owns (crm_depositos_sin_dueno, migration 380): the panel links one to an operation. */
export interface FreeDeposit {
  transId: string;
  amount: number;
  currency: string;
  receivedAt: string;
  holder: string | null;
}

export interface FreeDepositRpcRow {
  trans_id: string;
  amount: number | string;
  currency: string;
  received_at: string;
  holder: string | null;
}

export interface ChatImage {
  id: string;
  wamid: string;
  createdAt: string;
  senderType: string;
  mediaUrl: string;
}

export interface ChatImageRpcRow {
  id: string;
  message_id: string;
  created_at: string;
  sender_type: string;
  media_url: string;
}
