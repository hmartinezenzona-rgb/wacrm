"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useAuth } from "@/hooks/use-auth";
import { useCan } from "@/hooks/use-can";
import { createClient } from "@/lib/supabase/client";
import type { ConversationOperationsRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { RemittanceOperationCard } from "./remittance-operation-card";
import { ResolverStateBanner } from "./resolver-state-banner";

/** How long to wait after a `deals` change before refetching — n8n's sync
 *  triggers can fire several UPDATEs on the same deal in quick succession
 *  (one per field group), so a short debounce coalesces a burst into one
 *  fetch instead of refetching per event. */
const REALTIME_REFRESH_DEBOUNCE_MS = 800;

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
  // Bumped after every silent refetch (realtime-triggered or from a card's
  // own `onChanged`) and forwarded down to `DepositReviewContainer` so it
  // re-fetches its receipts too, without either side flashing a loading
  // state.
  const [refreshToken, setRefreshToken] = useState(0);

  const applyLoadedData = useCallback((data: ConversationOperationsRead) => {
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
  }, []);

  const load = useCallback(
    async (id: string) => {
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
        applyLoadedData(data);
      } catch {
        setState({ status: "error" });
      }
    },
    [applyLoadedData],
  );

  // Same fetch as `load`, but never switches the UI to the loading state
  // and never shows an error screen on failure — used for background
  // refreshes (realtime `deals` changes, a card's own `onChanged`) where
  // flashing "Loading…" or wiping the panel on a transient failure would
  // be worse than briefly showing stale data.
  const silentLoad = useCallback(
    async (id: string) => {
      try {
        const response = await fetch(
          `/api/remittance-operations?conversationId=${id}`,
          { cache: "no-store" },
        );
        if (!response.ok) return;
        const data = (await response.json()) as ConversationOperationsRead;
        applyLoadedData(data);
        setRefreshToken((token) => token + 1);
      } catch {
        // Keep whatever is currently rendered.
      }
    },
    [applyLoadedData],
  );

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

  // Live refresh: every automation write to remittance_operations/
  // remittance_beneficiaries (n8n) happens inside the same transaction as
  // an UPDATE/INSERT on `deals` (sync triggers) — `deals` is in the
  // `supabase_realtime` publication, the remittance_* tables aren't. So we
  // subscribe to `deals` changes for this conversation and treat any of
  // them as "something here may have changed", debounced so a burst of
  // per-field UPDATEs from one sync only refetches once.
  useEffect(() => {
    if (!conversationId) return;
    const supabase = createClient();
    let debounceTimer: ReturnType<typeof setTimeout> | null = null;

    const scheduleSilentRefetch = () => {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        debounceTimer = null;
        silentLoad(conversationId);
      }, REALTIME_REFRESH_DEBOUNCE_MS);
    };

    const channel = supabase
      .channel(`operations-panel-${conversationId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "deals", filter: `conversation_id=eq.${conversationId}` },
        scheduleSilentRefetch,
      )
      .subscribe();

    return () => {
      if (debounceTimer) clearTimeout(debounceTimer);
      supabase.removeChannel(channel);
    };
  }, [conversationId, silentLoad]);

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
                onChanged={() => silentLoad(conversationId)}
                expanded={expandedId === operation.id}
                onToggle={toggleHandlerFor(operation.id)}
                conversationId={conversationId}
                refreshToken={refreshToken}
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
                onChanged={() => silentLoad(conversationId)}
                expanded={expandedId === operation.id}
                onToggle={toggleHandlerFor(operation.id)}
                conversationId={conversationId}
                refreshToken={refreshToken}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
