"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { canForceVerify, type AccountRole } from "@/lib/auth/roles";
import { fetchOperationReceipts, forceVerifyDeposit, verifyDeposit } from "@/lib/remittance-operations/commands";
import { AttachReceiptControl } from "./attach-receipt-control";
import { ConsumedDepositsControl } from "./consumed-deposits-control";
import { FreeDepositsPicker } from "./free-deposits-picker";
import type { OperationReceiptsRead, VerifyDepositItem } from "@/lib/remittance-operations/types";
import { Skeleton } from "@/components/dashboard/skeleton";
import { DepositReviewSection, type SummaryAmount } from "./deposit-review-section";

interface DepositReviewContainerProps {
  operationId: string;
  /** Current user can correct/act on this operation — same gate the card
   *  already uses for its own edit affordances (role agent or higher,
   *  and the operation is not terminal). */
  canEdit: boolean;
  role: AccountRole | null;
  /** Called after a verify/force attempt actually changes the operation's
   *  stage, so the panel container refetches the operation list/status. */
  onChanged: () => void;
  /** Passed straight through to `DepositReviewSection` — the card computes
   *  these, this container has no opinion on them. */
  summaryAmount?: SummaryAmount | null;
  onAddAmount?: () => void;
  /** Bumped by the panel container after a silent refetch (realtime
   *  `deals` change). A change after mount triggers a silent receipts
   *  refetch here too — no loading flash, existing section state is kept
   *  as-is aside from the replaced data. */
  refreshToken?: number;
  /** Receipts already fetched by the panel's own request (panel-26's
   *  `receiptsByOperationId` prefetch), forwarded down through the card.
   *  When present, this container starts already `loaded` from it and
   *  skips its own initial fetch entirely — the whole point being that
   *  the deposit block paints in the SAME round trip as the rest of the
   *  card instead of a second one. Every other fetch this container does
   *  (the `refreshToken` silent refetch, the post-verify/force `load()`)
   *  is unaffected — only the very first fetch is skipped. Absent (the
   *  prefetch failed for this operation, or wasn't composed) falls back
   *  to fetching here exactly as before. */
  initialData?: OperationReceiptsRead;
  /** The other open operations of the same conversation: where a verified deposit can be moved (migration 381). */
  moveTargets?: { id: string; label: string }[];
  /** The operation's conversation: where the "attach a receipt from the chat" picker reads the images (migration 382). */
  conversationId?: string;
}

type ResultBanner = { kind: "success" | "error"; message: string } | null;

type FetchState = { status: "loading" } | { status: "error" } | { status: "loaded"; data: OperationReceiptsRead };

/** Success kind only for these two — every other known `resultado` value
 *  is rendered as an error message even though the request itself
 *  succeeded (e.g. "verificado_de_mas" moved the operation to incident). */
const SUCCESS_RESULTS: ReadonlyArray<string> = ["verificado", "verificado_incompleto"];

/** Every `resultado` value `crm_verificar_deposito` can return, mapped to
 *  `depositReview.results.*`; anything else falls back to `results.other`. */
const KNOWN_RESULTS: ReadonlyArray<string> = [
  "verificado",
  "verificado_incompleto",
  "verificado_de_mas",
  "monto_no_coincide",
  "ya_reclamado",
  "deposito_antiguo",
  "deposito_anulado",
  "sin_correo",
  "sin_referencia",
  "no_aplica",
];

/**
 * Container: fetches `crm_comprobantes_de_operacion` (via
 * `fetchOperationReceipts`) for one operation and renders the
 * presentational `DepositReviewSection` with the result. Owns the
 * verify/force network calls and maps their outcome to one of the
 * `depositReview.results.*` messages. A verify/force attempt that
 * actually changes the operation's stage — `result.stageChanged`, or
 * (defensively) whenever `resultado` starts with "verificado" — refetches
 * this operation's receipts and calls `onChanged()` so the panel-level
 * operation list/status reloads too. Renders nothing when there are no
 * receipts and verification isn't offered, so most cards (not in deposit
 * review) never show this block at all.
 */
export function DepositReviewContainer({
  operationId,
  canEdit,
  role,
  onChanged,
  summaryAmount,
  onAddAmount,
  refreshToken,
  initialData,
  moveTargets,
  conversationId,
}: DepositReviewContainerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [state, setState] = useState<FetchState>(() =>
    initialData ? { status: "loaded", data: initialData } : { status: "loading" },
  );
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<ResultBanner>(null);

  const load = useCallback(async () => {
    const response = await fetchOperationReceipts(operationId);
    if (!response.ok) {
      setState({ status: "error" });
      return;
    }
    setState({ status: "loaded", data: response.data });
  }, [operationId]);

  // Whether this container STARTED with prefetched data — captured once in
  // a ref rather than read from the `initialData` prop directly, so a
  // later prop change (the panel container re-rendering after its own
  // silent refetch) can never retrigger the initial-fetch effect below.
  // Only the very first render's `initialData` matters here; everything
  // after mount goes through `refreshToken`/`load()` instead.
  const hasInitialDataRef = useRef(initialData !== undefined);

  useEffect(() => {
    if (hasInitialDataRef.current) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load();
  }, [load]);

  // Silent refresh: a `refreshToken` bump after mount (never the initial
  // mount itself, which the effect above already handles) means the panel
  // container saw a `deals` change and wants receipts re-fetched — without
  // switching to the loading state or wiping the section on failure.
  const didMountRef = useRef(false);

  const refetchSilently = useCallback(async () => {
    const response = await fetchOperationReceipts(operationId);
    if (!response.ok) return;
    setState({ status: "loaded", data: response.data });
  }, [operationId]);

  useEffect(() => {
    if (!didMountRef.current) {
      didMountRef.current = true;
      return;
    }
    // eslint-disable-next-line react-hooks/set-state-in-effect
    refetchSilently();
  }, [refreshToken, refetchSilently]);

  function messageForResultado(resultado: string): { kind: "success" | "error"; message: string } {
    const isSuccess = SUCCESS_RESULTS.includes(resultado);
    if (KNOWN_RESULTS.includes(resultado)) {
      return { kind: isSuccess ? "success" : "error", message: t(`depositReview.results.${resultado}`) };
    }
    return { kind: "error", message: t("depositReview.results.other", { code: resultado }) };
  }

  async function handleVerify(items: VerifyDepositItem[], notify: boolean) {
    setBusy(true);
    const response = await verifyDeposit(operationId, items, notify);
    setBusy(false);

    if (!response.ok) {
      setResult({ kind: "error", message: response.status === 409 ? t("depositReview.conflict") : response.error });
      return;
    }

    const { result: outcome } = response;
    setResult(messageForResultado(outcome.resultado));

    if (outcome.stageChanged || outcome.resultado.startsWith("verificado")) {
      await load();
      onChanged();
    }
  }

  async function handleForce(notify: boolean) {
    setBusy(true);
    const response = await forceVerifyDeposit(operationId, notify);
    setBusy(false);

    if (!response.ok) {
      setResult({ kind: "error", message: response.status === 409 ? t("depositReview.conflict") : response.error });
      return;
    }

    setResult({ kind: "success", message: t("depositReview.forced") });
    await load();
    onChanged();
  }

  if (state.status === "loading") {
    // A skeleton in the block's own shape — same fix as the panel
    // container's own loading state (operations-panel-container.tsx):
    // this only renders when `initialData` wasn't given (no prefetch, or
    // the prefetch failed for this operation), so a text line here would
    // otherwise be the LAST thing to paint in the card, right after
    // everything else has already settled. The translated message stays
    // for screen readers, which had it before and get nothing from a
    // pulsing block.
    return (
      <div className="space-y-1" role="status" aria-busy="true">
        <span className="sr-only">{t("depositReview.loading")}</span>
        <div className="flex items-center gap-2">
          <Skeleton className="size-3.5 shrink-0 rounded-full" />
          <Skeleton className="h-4 w-32" />
        </div>
        <div className="flex items-center gap-2">
          <Skeleton className="size-3.5 shrink-0 rounded-full" />
          <Skeleton className="h-4 w-24" />
        </div>
        <div className="flex items-center gap-2">
          <Skeleton className="size-3.5 shrink-0 rounded-full" />
          <Skeleton className="h-4 w-40" />
        </div>
      </div>
    );
  }

  if (state.status === "error") {
    return <p className="px-1 py-1 text-xs text-destructive">{t("depositReview.loadError")}</p>;
  }

  const { data } = state;
  const canVerify = data.canVerify && canEdit;
  const canForce = role !== null && canForceVerify(role);
  const isOpen = data.status !== "completed" && data.status !== "cancelled";
  const canAttach = canEdit && Boolean(conversationId) && isOpen;
  const canMoveDeposit = canEdit && isOpen && data.consumedDeposits.length > 0;
  // The attach and the deposit-release controls live outside the verification stage: an open
  // operation with no receipts still needs its chat image attached (staging, 2026-11-17).
  const showSection = data.receipts.length > 0 || canVerify;

  if (!showSection && !canAttach && !canMoveDeposit) return null;

  return (
    <>
      {showSection && (
        <DepositReviewSection
          data={data}
          canVerify={canVerify}
          canForce={canForce}
          busy={busy}
          result={result}
          onVerify={handleVerify}
          onForce={handleForce}
          summaryAmount={summaryAmount}
          onAddAmount={onAddAmount}
        />
      )}
      {canAttach && (
        // (382) An image of the chat becomes a receipt of this operation (it verifies nothing: the verify above does).
        <AttachReceiptControl operationId={operationId} conversationId={conversationId!} onAttached={load} />
      )}
      {canMoveDeposit && (
        // (381) A verified deposit is released (free again) or moved to another open operation of the conversation.
        <ConsumedDepositsControl
          operationId={operationId}
          deposits={data.consumedDeposits}
          targets={moveTargets ?? []}
          onMoved={async () => {
            await load();
            onChanged();
          }}
        />
      )}
      {canVerify && (
        // (380) A deposit of the MMG ledger nobody owns is linked with the same verify: its TransID and amount.
        <FreeDepositsPicker
          operationId={operationId}
          busy={busy}
          onLink={(deposit, notify) => handleVerify([{ ref: deposit.transId, amount: deposit.amount }], notify)}
        />
      )}
    </>
  );
}
