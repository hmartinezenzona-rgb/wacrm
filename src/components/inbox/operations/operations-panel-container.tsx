"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useAuth } from "@/hooks/use-auth";
import { useCan } from "@/hooks/use-can";
import { canForceVerify } from "@/lib/auth/roles";
import { Button } from "@/components/ui/button";
import { useServiceName } from "@/hooks/use-service-name";
import { formatNumber } from "@/lib/format-number";
import { currentServiceOf } from "@/lib/remittance-operations/services";
import { createClient } from "@/lib/supabase/client";
import { Skeleton } from "@/components/dashboard/skeleton";
import { readPrefetchedConversationOperations } from "@/lib/remittance-operations/panel-prefetch";
import type { ConversationOperationsRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";
import { completableGroup, groupOperations, limitBlocks } from "./mixed-groups";
import { CompleteMixedSendSection, type CompleteMixedSendPart } from "./complete-mixed-send-section";
import { MixedCloseControl } from "./mixed-close-control";
import { MixedSendBlock } from "./mixed-send-block";
import { RemittanceOperationCard, isZelleOperation, needsServiceToClose } from "./remittance-operation-card";
import { otherOpenOperationsFor } from "./reassign-targets";

/** How long to wait after a `remittance_operations` change before
 *  refetching — the recalc/touch triggers can fire several UPDATEs on the
 *  same operation row in quick succession, so a short debounce coalesces a
 *  burst into one fetch instead of refetching per event. */
const REALTIME_REFRESH_DEBOUNCE_MS = 800;

/** Makes each mounted panel's realtime topic unique. realtime-js hands back
 *  the EXISTING channel for a topic that is already live, and adding a
 *  listener to it after `subscribe()` throws — which took the whole inbox
 *  down on mobile, where the desktop rail (hidden with CSS, still mounted)
 *  and the mobile contact sheet each render a panel for the same chat. */
let realtimeTopicSeq = 0;

/** History rows shown once the History section is opened, before "Show
 *  more" — the RPC already caps history at the latest 10 completed ops. */
const HISTORY_VISIBLE_COUNT = 5;

interface OperationsPanelContainerProps {
  /** Active conversation id, or `null` when no conversation is selected. */
  conversationId: string | null;
}

type PanelState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "error" }
  | { status: "loaded"; data: ConversationOperationsRead };

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
  // Lazy initializer (not a plain object) so a hover/focus prefetch that
  // already landed for `conversationId` (panel-26: conversation-list.tsx
  // fires it on mouseenter/focus) is read during THIS render, before
  // React commits anything — the loading skeleton never paints for a
  // hit. It only covers the very first mount of this component instance;
  // switching `conversationId` on an already-mounted instance is handled
  // by the effect below, which re-checks the cache on every change.
  const [state, setState] = useState<PanelState>(() => {
    if (conversationId) {
      const cached = readPrefetchedConversationOperations(conversationId);
      if (cached) return { status: "loaded", data: cached };
    }
    return { status: "idle" };
  });
  const [expandedId, setExpandedId] = useState<string | null>(null);
  // The open group action of a mixed send: its inline "Completar envio" or its "Cerrar manualmente". The completion's
  // parts are a snapshot taken on open: a delivered part turns into history on the next refetch, and the section must
  // keep showing it (done) until the operator closes it.
  const [groupAction, setGroupAction] = useState<
    { conversationId: string; groupId: string; kind: "complete"; parts: CompleteMixedSendPart[] } | { conversationId: string; groupId: string; kind: "close" } | null
  >(null);
  const serviceName = useServiceName();
  // History is hidden until asked for, and shows only the latest
  // HISTORY_VISIBLE_COUNT until "Show more". Both are stored as the
  // conversation they were opened for (not a boolean) so switching
  // conversations on this same instance starts collapsed again without
  // a reset effect.
  const [historyOpenFor, setHistoryOpenFor] = useState<string | null>(null);
  const [historyShowAllFor, setHistoryShowAllFor] = useState<string | null>(null);
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
  // refreshes (realtime `remittance_operations` changes, a card's own
  // `onChanged`) where flashing "Loading…" or wiping the panel on a
  // transient failure would be worse than briefly showing stale data.
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
    if (!conversationId) return;
    // Same prefetch-cache check the lazy initializer above does, run
    // again here so switching between two already-loaded conversations
    // (this component stays mounted across a selection change — see
    // contact-sidebar.tsx) ALSO skips the loading skeleton on a hit. A
    // hit paints straight from the cache, then revalidates silently
    // (existing `silentLoad`, no loading flash) so a cache that's stale
    // by a few seconds self-corrects. A miss keeps the exact prior
    // behaviour: `load` sets state inside an async callback, same as
    // `fetchContactData()` in contact-sidebar.tsx just above this file.
    const cached = readPrefetchedConversationOperations(conversationId);
    if (cached) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      applyLoadedData(cached);
      silentLoad(conversationId);
    } else {
      load(conversationId);
    }
  }, [conversationId, load, silentLoad, applyLoadedData]);

  // Live refresh: subscribe directly to `remittance_operations` for this
  // conversation. Every command that changes what the panel renders writes
  // that row — the panel's own RPCs and the bot's create/register-deposit
  // paths alike — so any change here means "something may have changed".
  // We treat all of them the same and debounce, because one operation write
  // can cascade into several row updates from the recalc/touch triggers.
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

    realtimeTopicSeq += 1;
    const channel = supabase
      .channel(`operations-panel-${conversationId}-${realtimeTopicSeq}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "remittance_operations", filter: `conversation_id=eq.${conversationId}` },
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
    // A skeleton in the panel's own shape, not a line of text. The text
    // was one small paragraph that the loaded panel then replaced with a
    // heading and full-width cards, so the sidebar visibly reflowed a
    // moment after the chat opened and the panel read as arriving late.
    // Occupying the final layout from the first paint removes the jump;
    // the data still takes as long as it takes.
    //
    // The message itself stays for screen readers, which had it before
    // and get nothing from a pulsing rectangle.
    return (
      <div className="space-y-2" role="status" aria-busy="true">
        <span className="sr-only">{t("loading")}</span>
        <Skeleton className="mx-1 h-3 w-28" />
        <div className="rounded-lg border border-border bg-card px-2 py-2.5">
          <div className="flex items-center gap-2">
            <Skeleton className="h-4 flex-1" />
            <Skeleton className="size-4 shrink-0 rounded-full" />
          </div>
          <div className="mt-1.5 flex items-center gap-1.5">
            <Skeleton className="h-4 w-20 rounded-full" />
            <Skeleton className="h-4 w-24 rounded-full" />
          </div>
        </div>
      </div>
    );
  }

  if (state.status === "error") {
    return <p className="px-1 py-2 text-xs text-destructive">{t("loadError")}</p>;
  }

  const { data } = state;

  // History rows (migration 102) never affect the resolver banner or the
  // single-open-op auto-expand rule — both stay scoped to open operations.
  const openOperations = data.operations.filter((operation) => !operation.isHistory);
  const historyOperations = data.operations.filter((operation) => operation.isHistory);
  const historyOpen = historyOpenFor !== null && historyOpenFor === conversationId;
  const historyShowAll = historyShowAllFor !== null && historyShowAllFor === conversationId;
  // A completed mixed send reads as one block; its members are looked up among the history only, so the header lists
  // exactly the cards under it. The limit counts a block as one entry, so a group is never cut in half.
  const historyBlocks = groupOperations(historyOperations, historyOperations);
  const { visible: visibleHistory, hiddenOperations: hiddenHistoryCount } = limitBlocks(
    historyBlocks,
    historyShowAll ? historyBlocks.length : HISTORY_VISIBLE_COUNT,
  );

  const partOf = (member: RemittanceOperationRead): CompleteMixedSendPart => ({
    id: member.id,
    method: currentServiceOf(member),
    title: `${serviceName(currentServiceOf(member))} · ${formatNumber(member.quotedSourceAmount ?? 0)} GYD`,
    isZelle: isZelleOperation(member),
    beneficiaries: member.beneficiaries.map((b) => ({ id: b.id, isZelle: b.beneficiaryType === "zelle" })),
  });

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
          <div className="space-y-2">
            {groupOperations(openOperations, data.operations).map((block) => {
              const groupId = block.grouped ? block.members[0]!.mixedGroupId : null;
              const action = groupAction && groupAction.conversationId === conversationId && groupAction.groupId === groupId ? groupAction : null;
              // One verified deposit pays the whole send: one "Completar envio" instead of one per part.
              const group = canEdit && block.grouped ? completableGroup(block.members, data.receiptsByOperationId) : null;
              const completing = action?.kind === "complete";
              // The group's own "Cerrar manualmente" is only for an owner/admin and when no member needs a service picked.
              const canCloseGroup =
                group !== null && accountRole !== null && canForceVerify(accountRole) && block.operations.every((member) => !needsServiceToClose(member));
              const cards = block.operations.map((operation) => (
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
                  initialReceipts={data.receiptsByOperationId?.[operation.id]}
                  mixedMembers={block.members}
                  completedByGroup={group !== null || completing}
                  closedByGroup={canCloseGroup}
                  // The quote belongs to the conversation, not to one
                  // operation: show it once, on the newest open card.
                  quote={operation.id === openOperations[0]?.id ? data.quote : null}
                />
              ));
              if (!block.grouped) return cards;
              const dismiss = () => setGroupAction(null);
              return (
                <MixedSendBlock
                  key={groupId}
                  members={block.members}
                  statusChip={group || completing ? { status: "ready_to_transfer", label: t("status.ready_to_transfer") } : undefined}
                  depositTransId={group?.deposit.transId}
                  section={
                    action?.kind === "complete" ? (
                      <CompleteMixedSendSection
                        conversationId={conversationId}
                        parts={action.parts}
                        onClose={(anyDone) => {
                          dismiss();
                          if (anyDone) silentLoad(conversationId);
                        }}
                      />
                    ) : undefined
                  }
                  actions={
                    group ? (
                      action?.kind === "close" ? (
                        <MixedCloseControl
                          operationIds={block.operations.map((member) => member.id)}
                          onDone={() => {
                            dismiss();
                            silentLoad(conversationId);
                          }}
                          onCancel={dismiss}
                        />
                      ) : (
                        <>
                          <Button
                            type="button"
                            size="lg"
                            className="w-full"
                            onClick={() => setGroupAction({ conversationId, groupId: groupId!, kind: "complete", parts: block.members.map((member) => partOf(member)) })}
                          >
                            {t("mixedSend.complete")}
                          </Button>
                          {canCloseGroup && (
                            <Button
                              type="button"
                              variant="outline"
                              size="lg"
                              className="w-full"
                              onClick={() => setGroupAction({ conversationId, groupId: groupId!, kind: "close" })}
                            >
                              {t("closing.closeButton")}
                            </Button>
                          )}
                        </>
                      )
                    ) : undefined
                  }
                >
                  {cards}
                </MixedSendBlock>
              );
            })}
          </div>
        </>
      )}

      {historyOperations.length > 0 && (
        <div className="space-y-2">
          <h3 className="px-1 text-xs font-semibold uppercase tracking-[0.14em] text-muted-foreground">
            <button
              type="button"
              aria-expanded={historyOpen}
              className="flex items-center gap-1 uppercase tracking-[0.14em] hover:text-foreground"
              onClick={() => setHistoryOpenFor(historyOpen ? null : conversationId)}
            >
              {`${t("historyTitle")} (${historyOperations.length})`}
            </button>
          </h3>
          {historyOpen && (
            <div className="space-y-2">
              {visibleHistory.map((block) => {
                const cards = block.operations.map((operation) => (
                  <RemittanceOperationCard
                    key={operation.id}
                    operation={operation}
                    // A history op must never be passed editable/canForce —
                    // the card itself also guards on `operation.isHistory`,
                    // this is the same invariant enforced at the boundary too.
                    canEdit={false}
                    role={null}
                    costRole={accountRole}
                    otherOpenOperations={[]}
                    onChanged={() => silentLoad(conversationId)}
                    expanded={expandedId === operation.id}
                    onToggle={toggleHandlerFor(operation.id)}
                    conversationId={conversationId}
                    refreshToken={refreshToken}
                    initialReceipts={data.receiptsByOperationId?.[operation.id]}
                  />
                ));
                return block.grouped ? (
                  <MixedSendBlock key={block.members[0]!.mixedGroupId} members={block.members}>
                    {cards}
                  </MixedSendBlock>
                ) : (
                  cards
                );
              })}
              {hiddenHistoryCount > 0 && (
                <button
                  type="button"
                  className="w-full text-center text-xs text-muted-foreground underline underline-offset-2"
                  onClick={() => setHistoryShowAllFor(conversationId)}
                >
                  {t("historyShowMore", { count: hiddenHistoryCount })}
                </button>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
