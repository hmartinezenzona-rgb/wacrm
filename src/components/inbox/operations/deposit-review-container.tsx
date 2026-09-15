"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { canForceVerify, type AccountRole } from "@/lib/auth/roles";
import { fetchOperationReceipts, forceVerifyDeposit, verifyDeposit } from "@/lib/remittance-operations/commands";
import type { OperationReceiptsRead, VerifyDepositItem } from "@/lib/remittance-operations/types";
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
}: DepositReviewContainerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [state, setState] = useState<FetchState>({ status: "loading" });
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

  useEffect(() => {
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

  async function handleVerify(items: VerifyDepositItem[]) {
    setBusy(true);
    const response = await verifyDeposit(operationId, items);
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

  async function handleForce(reason: string) {
    setBusy(true);
    const response = await forceVerifyDeposit(operationId, reason);
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
    return <p className="px-1 py-1 text-xs text-muted-foreground">{t("depositReview.loading")}</p>;
  }

  if (state.status === "error") {
    return <p className="px-1 py-1 text-xs text-destructive">{t("depositReview.loadError")}</p>;
  }

  const { data } = state;
  const canVerify = data.canVerify && canEdit;
  const canForce = role !== null && canForceVerify(role);

  if (data.receipts.length === 0 && !canVerify) return null;

  return (
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
  );
}
