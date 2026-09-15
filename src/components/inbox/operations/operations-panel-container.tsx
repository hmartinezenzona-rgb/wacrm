"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useAuth } from "@/hooks/use-auth";
import { useCan } from "@/hooks/use-can";
import type { ConversationOperationsRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { RemittanceOperationCard } from "./remittance-operation-card";
import { ResolverStateBanner } from "./resolver-state-banner";

interface OperationsPanelContainerProps {
  /** Active conversation id, or `null` when no conversation is selected. */
  conversationId: string | null;
}

type PanelState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "error" }
  | { status: "loaded"; data: ConversationOperationsRead };

/** The RPC never returns these (see types.ts) — same defensive exclusion
 *  as `remittance-operation-card.tsx`. */
const TERMINAL_STATUSES: ReadonlyArray<string> = ["completed", "cancelled"];

/** Other open operations of the same conversation, offered as
 *  reassignment targets for `operation`'s beneficiaries. */
function otherOpenOperationsFor(
  operation: RemittanceOperationRead,
  operations: RemittanceOperationRead[],
): { id: string; label: string }[] {
  return operations
    .filter((candidate) => candidate.id !== operation.id && !TERMINAL_STATUSES.includes(candidate.status))
    .map((candidate) => ({
      id: candidate.id,
      label: `${candidate.quotedSourceAmount ?? "?"} ${candidate.sourceCurrency ?? ""} → ${candidate.destinationCurrency ?? ""}`,
    }));
}

/**
 * Container: fetches `GET /api/remittance-operations` for the active
 * conversation and owns loading/error/empty state. Passes each card
 * `canEdit` (role agent or higher), its reassignment targets, and
 * `onChanged` (refetch) so Slice 6's correction/reassignment UI can act.
 * Mounted only behind `profiles.beta_features` containing
 * 'operations_panel' (design decision 8; see `contact-sidebar.tsx`).
 *
 * Also owns the panel's accordion state (`expandedId`): only one
 * operation's details are shown at a time. It defaults to the single
 * operation when there's exactly one, otherwise starts collapsed, and
 * stays on the previously-expanded operation across a refetch when it's
 * still present (e.g. after a correction) — a new conversation's data
 * never contains the previous id, so switching conversations naturally
 * resets to collapsed/auto-expanded.
 */
export function OperationsPanelContainer({ conversationId }: OperationsPanelContainerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const canEdit = useCan("send-messages");
  // `useCan` already composes with `useAuth` internally (see use-can.ts) —
  // read straight from it here too so the deposit review container can
  // gate its force-verify escalation (`canForceVerify`, owner/admin only)
  // without new plumbing from contact-sidebar/profile.
  const { accountRole } = useAuth();
  const [state, setState] = useState<PanelState>({ status: "idle" });
  const [expandedId, setExpandedId] = useState<string | null>(null);

  const load = useCallback(async (id: string) => {
    setState({ status: "loading" });
    try {
      const response = await fetch(
        `/api/remittance-operations?conversationId=${id}`,
        { cache: "no-store" },
      );
      if (!response.ok) {
        setState({ status: "error" });
        return;
      }
      const data = (await response.json()) as ConversationOperationsRead;
      setState({ status: "loaded", data });
      // Auto-expand only ever considers OPEN operations — a lone history
      // row must never auto-open (design: "History card ... COLLAPSED by
      // default"). Staying on a previously-expanded id (open or history)
      // across a refetch is unaffected by that scoping.
      const openOperations = data.operations.filter((op) => !op.isHistory);
      setExpandedId((previous) =>
        data.operations.some((op) => op.id === previous)
          ? previous
          : openOperations.length === 1
            ? openOperations[0].id
            : null,
      );
    } catch {
      setState({ status: "error" });
    }
  }, []);

  useEffect(() => {
    // No direct setState here on the `!conversationId` path — deselecting
    // the active conversation leaves `state` stale on purpose. The render
    // below gates on `conversationId` first, so stale data is never shown.
    // `load` sets state inside an async callback, same as
    // `fetchContactData()` in contact-sidebar.tsx just above this file.
    if (conversationId) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      load(conversationId);
    }
  }, [conversationId, load]);

  if (!conversationId) return null;

  if (state.status === "idle" || state.status === "loading") {
    return <p className="px-1 py-2 text-xs text-muted-foreground">{t("loading")}</p>;
  }

  if (state.status === "error") {
    return <p className="px-1 py-2 text-xs text-destructive">{t("loadError")}</p>;
  }

  const { data } = state;

  // History rows (migration 102) never affect the resolver banner or the
  // single-open-op auto-expand rule — both stay scoped to open operations.
  const openOperations = data.operations.filter((operation) => !operation.isHistory);
  const historyOperations = data.operations.filter((operation) => operation.isHistory);

  const toggleHandlerFor = (operationId: string) => () =>
    setExpandedId((current) => (current === operationId ? null : operationId));

  return (
    <div className="space-y-2">
      {data.resolverState === "ninguna" ? (
        <p className="px-1 py-2 text-xs text-muted-foreground">{t("noOpenOperations")}</p>
      ) : (
        <>
          <h3 className="px-1 text-xs font-semibold uppercase tracking-[0.14em] text-muted-foreground">
            {t("title")}
          </h3>
          {data.resolverState === "ambigua" && (
            <ResolverStateBanner candidateCount={data.resolverCandidateCount} />
          )}
          <div className="space-y-2">
            {openOperations.map((operation) => (
              <RemittanceOperationCard
                key={operation.id}
                operation={operation}
                canEdit={canEdit}
                role={accountRole}
                otherOpenOperations={otherOpenOperationsFor(operation, openOperations)}
                onChanged={() => load(conversationId)}
                expanded={expandedId === operation.id}
                onToggle={toggleHandlerFor(operation.id)}
                conversationId={conversationId}
              />
            ))}
          </div>
        </>
      )}

      {historyOperations.length > 0 && (
        <div className="space-y-2">
          <h3 className="px-1 text-xs font-semibold uppercase tracking-[0.14em] text-muted-foreground">
            {t("historyTitle")}
          </h3>
          <div className="space-y-2">
            {historyOperations.map((operation) => (
              <RemittanceOperationCard
                key={operation.id}
                operation={operation}
                // A history op must never be passed editable/canForce —
                // the card itself also guards on `operation.isHistory`,
                // this is the same invariant enforced at the boundary too.
                canEdit={false}
                role={null}
                otherOpenOperations={[]}
                onChanged={() => load(conversationId)}
                expanded={expandedId === operation.id}
                onToggle={toggleHandlerFor(operation.id)}
                conversationId={conversationId}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
