"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import type { ConversationOperationsRead } from "@/lib/remittance-operations/types";
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

/**
 * Container: fetches `GET /api/remittance-operations` for the active
 * conversation and owns loading/error/empty state. Read-only (Slice 5) —
 * no correction, verify, or delivery actions. Mounted only behind
 * `profiles.beta_features` containing 'operations_panel' (design
 * decision 8; see `contact-sidebar.tsx`).
 */
export function OperationsPanelContainer({ conversationId }: OperationsPanelContainerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [state, setState] = useState<PanelState>({ status: "idle" });

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

  if (data.resolverState === "ninguna") {
    return <p className="px-1 py-2 text-xs text-muted-foreground">{t("noOpenOperations")}</p>;
  }

  return (
    <div className="space-y-2">
      <h3 className="px-1 text-xs font-semibold uppercase tracking-[0.14em] text-muted-foreground">
        {t("title")}
      </h3>
      {data.resolverState === "ambigua" && (
        <ResolverStateBanner candidateCount={data.resolverCandidateCount} />
      )}
      <div className="space-y-2">
        {data.operations.map((operation) => (
          <RemittanceOperationCard key={operation.id} operation={operation} />
        ))}
      </div>
    </div>
  );
}
