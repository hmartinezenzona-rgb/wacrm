// ============================================================
// Maps the refusal messages of `crm_entregar_operacion` (SQLSTATE 22023,
// passed through by `rpcErrorResponse` as a 400 `{ error }`) to a message key
// plus params, so the panel can say WHY a delivery was refused instead of the
// generic "retry". The match is on the server text (migrations 101, 143, 329,
// 331); a message that matches nothing returns null and the caller shows the
// server text as is.
// ============================================================

export interface DeliveryRefusal {
  /** Key under `Inbox.operationsPanel.completeTransfer.refusal`. */
  key:
    | "notReady"
    | "beneficiariesIncomplete"
    | "fundingConflict"
    | "noSourceAmount"
    | "fundingMissing"
    | "recipientsMismatch"
    | "proofsMissing"
    | "usdInventoryInsufficient";
  params: Record<string, string | number>;
}

/** 6200 -> "6,200"; "6200.50" -> "6,200.5"; at most 2 decimals. */
export function formatAmount(raw: string): string {
  const n = Number(raw);
  if (!Number.isFinite(n)) return raw;
  return n.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

export function parseDeliveryRefusal(message: string): DeliveryRefusal | null {
  if (message.includes("operation is not ready to transfer")) {
    return { key: "notReady", params: {} };
  }
  if (message.includes("beneficiary data is incomplete")) {
    return { key: "beneficiariesIncomplete", params: {} };
  }
  const conflict = /the funding case has a conflict: ([\s\S]*)$/.exec(message);
  if (conflict) {
    return { key: "fundingConflict", params: { note: conflict[1].trim() } };
  }
  if (message.includes("no source amount to fund")) {
    return { key: "noSourceAmount", params: {} };
  }
  const funding = /has ([\d.]+) GYD of verified funding but needs ([\d.]+) GYD/.exec(message);
  if (funding) {
    return {
      key: "fundingMissing",
      params: { deposited: formatAmount(funding[1]), required: formatAmount(funding[2]) },
    };
  }
  const sums = /add up to ([\d.]+)\s+(\S*?)\s*but the operation sends ([\d.]+)/.exec(message);
  if (sums) {
    return {
      key: "recipientsMismatch",
      params: {
        sum: formatAmount(sums[1]),
        sent: formatAmount(sums[3]),
        currency: sums[2],
      },
    };
  }
  const proofs = /every beneficiary needs its delivery proof.*\((\d+) missing\)/.exec(message);
  if (proofs) {
    return { key: "proofsMissing", params: { count: Number(proofs[1]) } };
  }
  // Migration 356: Clásica / Tropical balance is short -> `usd_inventory_insufficient:<SERVICE>:<missing_usd> (needs N USD, M USD available)`.
  const usd = /usd_inventory_insufficient:(CLASICA|TROPICAL):([\d.]+)/.exec(message);
  if (usd) {
    return {
      key: "usdInventoryInsufficient",
      params: { service: usd[1] === "CLASICA" ? "Clásica" : "Tropical", missing: formatAmount(usd[2]) },
    };
  }
  return null;
}
