"use client";

import { useState, useEffect, useRef, useCallback, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Pipeline, PipelineStage, Deal } from "@/types";
import { PipelineBoard } from "@/components/pipelines/pipeline-board";
import { PipelineSettings } from "@/components/pipelines/pipeline-settings";
import { DealForm } from "@/components/pipelines/deal-form";
import { PipelineAnalytics } from "@/components/pipelines/pipeline-analytics";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { GitBranch, Plus, ChevronDown, Settings } from "lucide-react";
import { toast } from "sonner";
import { useCan } from "@/hooks/use-can";
import { useAuth } from "@/hooks/use-auth";
import { GatedButton } from "@/components/ui/gated-button";
import { useTranslations } from "next-intl";
import {
  uploadAccountMedia,
  deleteAccountMedia,
} from "@/lib/storage/upload-media";
import { CHAT_MEDIA_BUCKET } from "@/components/inbox/message-composer";
import {
  draftBelongsTo,
  PROOF_MAX_BYTES,
  type ProofImageKind,
  type ProofRejection,
} from "@/lib/pipelines/delivery-proof";
import {
  deliverDeal,
  type DeliveryDeps,
  type DeliveryResult,
} from "@/lib/pipelines/deliver-with-proof";
import {
  DELIVERED_STAGE_ID,
  DELIVERY_PROOF_STAGE_ID,
  isDeliveredStage,
} from "@/lib/pipelines/delivery-stages";
import {
  markProofSent,
  pruneStaleDrafts,
  putProofDraft,
  removeProofDraft,
  revokeAllPreviews,
  setProofCaption,
  type ProofDrafts,
} from "@/lib/pipelines/proof-drafts";
import { sessionWindowFrom } from "@/lib/inbox/session-window";
import { fetchLastCustomerMessageAt } from "@/lib/inbox/last-customer-message";

// Pipeline creation is admin-class (settings-tier write under
// the new RLS); deal creation is operational and only requires
// agent+. The two CTAs gate on different `useCan` capabilities,
// not on different copy.

// Spec-defined seed — name and color per the product spec.
const SPEC_DEFAULT_STAGES = [
  { name: "New Lead", color: "#3b82f6", position: 0 }, // blue
  { name: "Qualified", color: "#eab308", position: 1 }, // yellow
  { name: "Proposal Sent", color: "#f97316", position: 2 }, // orange
  { name: "Negotiation", color: "#8b5cf6", position: 3 }, // purple
  { name: "Won", color: "#22c55e", position: 4 }, // green
];

export default function PipelinesPage() {
  const t = useTranslations("Pipelines.page");
  const tProof = useTranslations("Pipelines.deliveryProof");
  const tConfirm = useTranslations("Pipelines.deliveryConfirm");
  const supabase = createClient();
  const canEditSettings = useCan("edit-settings");
  const canCreateDeals = useCan("send-messages");
  const { accountId } = useAuth();

  const [pipelines, setPipelines] = useState<Pipeline[]>([]);
  const [selectedPipelineId, setSelectedPipelineId] = useState<string>("");
  const [stages, setStages] = useState<PipelineStage[]>([]);
  const [deals, setDeals] = useState<Deal[]>([]);
  const [loading, setLoading] = useState(true);

  // Dialog / sheet state
  const [newPipelineOpen, setNewPipelineOpen] = useState(false);
  const [newPipelineName, setNewPipelineName] = useState("");
  const [creating, setCreating] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Deal form state is lifted here so both the top-bar "Add Deal" and
  // the per-column "+" trigger the same Sheet.
  const [dealFormOpen, setDealFormOpen] = useState(false);
  const [editingDeal, setEditingDeal] = useState<Deal | null>(null);
  const [defaultStageId, setDefaultStageId] = useState<string>("");

  // Guard against double-seeding (React StrictMode double-effect in dev).
  const seedAttempted = useRef(false);

  // ---- Delivery proof ---------------------------------------------
  // Drafts are keyed by deal and live only for this session: never in
  // Storage (the file is not uploaded until the operator confirms),
  // never in localStorage, never in the database. Keying by deal is
  // what keeps deal A's screenshot from being sent to deal B.
  const [proofDrafts, setProofDrafts] = useState<ProofDrafts>(() => new Map());
  // Which deal is mid-delivery. Locks the confirm dialog, the proof
  // panel and a second drag; the authoritative lock is in
  // `deliverDeal` itself, this is the UI reflection of it.
  const [deliveringId, setDeliveringId] = useState<string | null>(null);
  // The dialog shown when a deal WITH a proof is dropped on Entregada.
  const [prompt, setPrompt] = useState<{
    deal: Deal;
    mode:
      | "confirm"
      | "window-closed"
      | "stage-failed"
      | "sent-not-recorded"
      | "unconfirmed";
    message?: string;
  } | null>(null);

  // The two browser calls the draft module needs. Bundled here so the
  // draft module itself stays testable under vitest's `node`
  // environment, where `URL.createObjectURL` does not exist.
  const objectUrls = useMemo(
    () => ({
      createUrl: (file: File) => URL.createObjectURL(file),
      revokeUrl: (url: string) => URL.revokeObjectURL(url),
    }),
    [],
  );

  // Read inside `adoptDeals`, which must not be rebuilt every time a
  // delivery starts or ends — it is a dependency of the load effect.
  const deliveringIdRef = useRef<string | null>(null);
  useEffect(() => {
    deliveringIdRef.current = deliveringId;
  }, [deliveringId]);

  /**
   * Adopt a freshly loaded board and drop any prepared proof it
   * invalidates. The board is live — n8n, another agent, or the same
   * person in another tab can move a deal while a screenshot sits
   * prepared — so every load is also the moment to notice.
   *
   * The delivery this tab is currently running is exempt: we are the
   * ones moving that deal to Entregada, and pruning it mid-flight
   * would pull the draft out from under the send.
   */
  const adoptDeals = useCallback(
    (loaded: Deal[]) => {
      setDeals(loaded);
      setProofDrafts((prev) =>
        pruneStaleDrafts(prev, loaded, DELIVERY_PROOF_STAGE_ID, objectUrls, {
          keepDealId: deliveringIdRef.current,
        }),
      );
    },
    [objectUrls],
  );

  const loadPipelines = useCallback(async () => {
    const { data, error } = await supabase
      .from("pipelines")
      .select("*")
      .order("created_at");
    if (error) {
      console.error("Failed to load pipelines:", error.message);
      return [];
    }
    return data ?? [];
  }, [supabase]);

  const loadStages = useCallback(
    async (pipelineId: string) => {
      const { data } = await supabase
        .from("pipeline_stages")
        .select("*")
        .eq("pipeline_id", pipelineId)
        .order("position");
      return data ?? [];
    },
    [supabase],
  );

  const loadDeals = useCallback(
    async (pipelineId: string) => {
      // Filtro de vista: mostrar lo abierto + lo entregado (won) DE HOY.
      // La columna "Entregada" acumulaba TODO el histórico
      // (~150 tarjetas/mes); con 7 días seguía juntando ~50 tarjetas y
      // Osmany pedía verla al día. Los datos NO se mueven ni se borran:
      // el histórico completo vive en la pantalla de resumen, que se
      // construye sobre `remittance_operations` + `remittance_beneficiaries`
      // y NO depende de `deals` — comprobado el 14-ago-2026 con dos
      // operaciones cuyo deal ya estaba borrado: siguen saliendo enteras.
      // Por eso aquí se acorta la ventana en vez de borrar deals: borrarlos
      // pondría a NULL `depositos_mmg.deal_id` (47 depósitos hoy) y se
      // perdería qué depósito pagó qué remesa.
      // `status.is.null` cubre los deals sin status (pipeline genérico,
      // nunca tocados por el trigger de remesas).
      // Inicio del DÍA DE NEGOCIO en Guyana (UTC-4 todo el año, sin
      // horario de verano), expresado en UTC.
      //
      // NO se corta a medianoche, y esto costó un susto: con el corte a las
      // 00:00, a las 00:13 la columna «Entregada» se vaciaba de golpe y
      // parecía que se hubieran borrado los envíos. Peor aún, seguía vacía
      // toda la mañana hasta la primera entrega del día — justo cuando uno
      // abre el CRM a repasar lo de ayer. Nada se borraba: era solo el
      // filtro. Pero un tablero que parece haber perdido los datos es un
      // tablero roto.
      //
      // Se corta a la hora de ABRIR (9:00). Entre las 00:00 y las 9:00 no se
      // entrega nada, así que hasta que el negocio abre se sigue viendo el
      // día anterior, y la columna cambia justo cuando empieza la jornada.
      //
      // Y se filtra por `entregado_en`, NO por `updated_at` (migración 083).
      // `updated_at` lo mueve un trigger en CUALQUIER edición, así que
      // tocar las notas de una remesa vieja la resucitaba en la columna de
      // hoy: pasó el 14-ago con una corrección en masa de 14 deals.
      // `entregado_en` solo se escribe al ENTRAR en la etapa Entregada.
      const APERTURA_GY = 9; // hora de Guyana a la que abre el negocio
      const gy = new Date(Date.now() - 4 * 60 * 60 * 1000);
      const inicio = new Date(
        Date.UTC(gy.getUTCFullYear(), gy.getUTCMonth(), gy.getUTCDate(),
                 APERTURA_GY + 4, 0, 0),
      );
      if (gy.getUTCHours() < APERTURA_GY) {
        inicio.setUTCDate(inicio.getUTCDate() - 1);
      }
      const since = inicio.toISOString();
      const { data } = await supabase
        .from("deals")
        .select(
          "*, contact:contacts(*), assignee:profiles!deals_assigned_to_fkey(*)",
        )
        .eq("pipeline_id", pipelineId)
        .or(
          `status.is.null,status.eq.open,and(status.eq.won,entregado_en.gte.${since})`,
        )
        .order("created_at", { ascending: false });
      return (data ?? []) as Deal[];
    },
    [supabase],
  );

  const seedDefaultPipeline = useCallback(async (): Promise<Pipeline | null> => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    const user = session?.user;
    if (!user) return null;
    // pipelines.account_id is NOT NULL post-017 with no DB default.
    if (!accountId) return null;

    const { data: pipeline, error } = await supabase
      .from("pipelines")
      .insert({ user_id: user.id, account_id: accountId, name: "Sales Pipeline" })
      .select()
      .single();

    if (error || !pipeline) {
      console.error("Failed to seed pipeline:", error?.message);
      return null;
    }

    const stagesPayload = SPEC_DEFAULT_STAGES.map((s) => ({
      pipeline_id: pipeline.id,
      name: s.name,
      color: s.color,
      position: s.position,
    }));
    await supabase.from("pipeline_stages").insert(stagesPayload);

    return pipeline as Pipeline;
  }, [supabase, accountId]);

  // Initial load + seed-if-empty
  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      let list = await loadPipelines();

      if (list.length === 0 && !seedAttempted.current) {
        seedAttempted.current = true;
        const seeded = await seedDefaultPipeline();
        if (seeded) list = await loadPipelines();
      }

      if (cancelled) return;
      setPipelines(list);
      if (list.length > 0) {
        setSelectedPipelineId((prev) =>
          prev && list.some((p) => p.id === prev) ? prev : list[0].id,
        );
      } else {
        setSelectedPipelineId("");
      }
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [loadPipelines, seedDefaultPipeline]);

  // Load stages + deals whenever selected pipeline changes.
  // Clearing on no-selection is a legitimate sync with URL/prop
  // state; the load completion uses async setters inside promise
  // callbacks (not synchronous in the effect body).
  useEffect(() => {
    if (!selectedPipelineId) {
      // (The two `react-hooks/set-state-in-effect` disables that used
      // to sit here were reported as unnecessary once this effect
      // gained `adoptDeals` as a dependency — the rule no longer fires
      // on either call.)
      setStages([]);
      setDeals([]);
      return;
    }
    let cancelled = false;
    (async () => {
      const [s, d] = await Promise.all([
        loadStages(selectedPipelineId),
        loadDeals(selectedPipelineId),
      ]);
      if (cancelled) return;
      setStages(s);
      adoptDeals(d as Deal[]);
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedPipelineId, loadStages, loadDeals, adoptDeals]);

  const refreshPipelines = useCallback(async () => {
    const list = await loadPipelines();
    setPipelines(list);
    if (list.length === 0) setSelectedPipelineId("");
    else if (!list.some((p) => p.id === selectedPipelineId))
      setSelectedPipelineId(list[0].id);
  }, [loadPipelines, selectedPipelineId]);

  const refreshStages = useCallback(async () => {
    if (!selectedPipelineId) return;
    setStages(await loadStages(selectedPipelineId));
  }, [loadStages, selectedPipelineId]);

  const refreshDeals = useCallback(async () => {
    if (!selectedPipelineId) return;
    adoptDeals(await loadDeals(selectedPipelineId));
  }, [loadDeals, selectedPipelineId, adoptDeals]);

  // Live updates: deals can be created/moved by external actors (the n8n
  // flow, another agent) — reload whenever the table changes so the board
  // reflects reality without a manual page refresh. RLS scopes the
  // realtime events to this account, same as the inbox.
  useEffect(() => {
    if (!selectedPipelineId) return;
    const channel = supabase
      .channel(`pipeline-deals-${selectedPipelineId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "deals" },
        () => {
          refreshDeals();
        },
      )
      .subscribe();
    return () => {
      supabase.removeChannel(channel);
    };
  }, [selectedPipelineId, supabase, refreshDeals]);

  // ---- Delivery proof: draft lifecycle -----------------------------

  // Mirror of the draft map for cleanup paths that must not re-run
  // when the map changes (unmount).
  const draftsRef = useRef(proofDrafts);
  useEffect(() => {
    draftsRef.current = proofDrafts;
  });

  // Every blob: URL this page hands out is revoked on unmount.
  // Navigating away from the board with a proof prepared would
  // otherwise leak the object for the life of the tab.
  useEffect(() => {
    return () => {
      revokeAllPreviews(draftsRef.current, {
        revokeUrl: (url) => URL.revokeObjectURL(url),
      });
    };
  }, []);

  /** Drop a draft and revoke its preview. Safe to call for a missing id. */
  const discardProofDraft = useCallback(
    (dealId: string) => {
      setProofDrafts((prev) => removeProofDraft(prev, dealId, objectUrls));
    },
    [objectUrls],
  );

  const handleProofFileAccepted = useCallback(
    // `kind` comes from `validateProofFile`, which read the actual
    // header bytes — it is not re-derived from the declared MIME.
    (dealId: string, file: File, kind: ProofImageKind) => {
      setProofDrafts((prev) =>
        putProofDraft(prev, dealId, file, kind, objectUrls),
      );
    },
    [objectUrls],
  );

  const handleProofRejected = useCallback(
    (reason: ProofRejection) => {
      const mb = Math.round(PROOF_MAX_BYTES / 1024 / 1024);
      toast.error(
        reason === "size"
          ? tProof("rejectSize", { mb })
          : reason === "mime"
            ? tProof("rejectMime")
            : reason === "empty"
              ? tProof("rejectEmpty")
              : tProof("rejectSignature"),
      );
    },
    [tProof],
  );

  const handleProofCaptionChange = useCallback(
    (dealId: string, caption: string) => {
      setProofDrafts((prev) => setProofCaption(prev, dealId, caption));
    },
    [],
  );

  // ---- Moving a deal ------------------------------------------------

  /**
   * The single place a deal's stage is written. Both the plain path
   * and the delivery path go through here, so there is one update to
   * reason about — and one trigger chain (`deals_stage_notify` → n8n →
   * the `remesa_completada` template) fired from one place.
   */
  /**
   * Is the 24-hour window open for this conversation right now?
   *
   * Asked twice per delivery on purpose: once to choose which dialog
   * the operator sees, and again inside `deliverDeal` just before the
   * upload, because a draft can sit prepared while the window runs out.
   * No conversation means no window.
   */
  const isWindowOpen = useCallback(
    async (conversationId: string | null | undefined) => {
      if (!conversationId) return false;
      const at = await fetchLastCustomerMessageAt(supabase, conversationId);
      return !sessionWindowFrom(at).expired;
    },
    [supabase],
  );

  const persistStage = useCallback(
    async (dealId: string, newStageId: string) => {
      const { error } = await supabase
        .from("deals")
        .update({ stage_id: newStageId })
        .eq("id", dealId);
      return error ? { ok: false as const, message: error.message } : { ok: true as const };
    },
    [supabase],
  );

  const handleDealMoved = useCallback(
    async (dealId: string, newStageId: string) => {
      const draft = proofDrafts.get(dealId);

      // A deal with a proof prepared, dropped on Entregada, is the ONLY
      // case that behaves differently. Everything else below this block
      // is the original code path, untouched — including the optimistic
      // move, which must not happen here: nothing has been sent yet and
      // the operator can still cancel.
      if (draft && isDeliveredStage(newStageId)) {
        const deal = deals.find((d) => d.id === dealId);
        if (deal) {
          if (deliveringId) {
            toast.error(tConfirm("busy"));
            return;
          }
          // Ask the window BEFORE showing the dialog so the operator
          // reads the right one: "send and deliver" or "you can't send,
          // deliver anyway?".
          const open = await isWindowOpen(deal.conversation_id);
          setPrompt({ deal, mode: open ? "confirm" : "window-closed" });
          return;
        }
      }

      // Optimistic update — board already animated; just persist.
      setDeals((prev) =>
        prev.map((d) => (d.id === dealId ? { ...d, stage_id: newStageId } : d)),
      );
      const moved = await persistStage(dealId, newStageId);
      if (!moved.ok) {
        toast.error(t("toastFailedMoveDeal"));
        refreshDeals();
      }
    },
    [
      proofDrafts,
      deals,
      deliveringId,
      isWindowOpen,
      persistStage,
      refreshDeals,
      t,
      tConfirm,
    ],
  );

  // A confirmation dialog must never outlive the draft it is about.
  //
  // Found in the manual gate (M-10): another session moved the deal
  // while the dialog was open, `pruneStaleDrafts` dropped the draft,
  // and the dialog stayed up still promising "se enviará la captura"
  // — with a confirm button that had quietly become a plain
  // "mark delivered". Nothing unsafe was sent, but the copy lied.
  useEffect(() => {
    if (!prompt) return;
    // Only the modes that exist BECAUSE a proof was prepared. The
    // recovery modes carry `sentWamid` and must stay open.
    if (prompt.mode !== "confirm" && prompt.mode !== "window-closed") return;
    if (deliveringId === prompt.deal.id) return; // ours, mid-flight
    if (proofDrafts.has(prompt.deal.id)) return;

    setPrompt(null);
    toast.error(tConfirm("staleStage"));
  }, [prompt, proofDrafts, deliveringId, tConfirm]);

  /**
   * Turn a `DeliveryResult` into what the operator sees.
   *
   * The one case worth reading twice is `stage-failed` with
   * `proofSent: true`: the customer HAS the screenshot but the deal
   * did not move. The draft is kept and stamped with the `wamid` so
   * the retry writes the stage only — re-sending would give them the
   * same image twice.
   */
  const handleDeliveryResult = useCallback(
    (deal: Deal, result: DeliveryResult) => {
      switch (result.status) {
        case "delivered": {
          discardProofDraft(deal.id);
          setPrompt(null);
          setDeals((prev) =>
            prev.map((d) =>
              d.id === deal.id ? { ...d, stage_id: DELIVERED_STAGE_ID } : d,
            ),
          );
          toast.success(
            result.proofSent
              ? tConfirm("okWithProof")
              : tConfirm("okWithoutProof"),
          );
          return;
        }

        case "window-closed": {
          // Shut between preparing and confirming — swap the dialog for
          // the one that offers delivery without the proof.
          setPrompt({ deal, mode: "window-closed" });
          return;
        }

        case "stage-failed": {
          if (result.proofSent) {
            setProofDrafts((prev) => markProofSent(prev, deal.id, result.wamid));
            setPrompt({ deal, mode: "stage-failed", message: result.message });
          } else {
            setPrompt(null);
            toast.error(t("toastFailedMoveDeal"));
            refreshDeals();
          }
          return;
        }

        case "sent-not-recorded": {
          // The customer HAS the image; only WaCRM's record is missing.
          // Same recovery as a failed stage update — mark it sent so a
          // retry can never re-send — but say plainly what happened,
          // because the message will not appear in the thread.
          setProofDrafts((prev) => markProofSent(prev, deal.id, result.wamid));
          setPrompt({ deal, mode: "sent-not-recorded" });
          return;
        }

        case "unconfirmed": {
          // Genuinely unknown. Do not mark it sent (that would block a
          // legitimate retry) and do not clear the draft (that would
          // lose the file). Send the operator to look at the thread.
          setPrompt({ deal, mode: "unconfirmed" });
          return;
        }

        case "stale-stage": {
          // Someone else moved it on. The draft is now meaningless.
          discardProofDraft(deal.id);
          setPrompt(null);
          toast.error(tConfirm("staleStage"));
          refreshDeals();
          return;
        }

        case "failed": {
          // Nothing moved and the file is still in memory, so the
          // operator can fix the cause and drag again.
          setPrompt(null);
          toast.error(
            result.phase === "upload"
              ? tConfirm("failUpload", { reason: result.message })
              : tConfirm("failSend", { reason: result.message }),
          );
          return;
        }

        case "blocked": {
          setPrompt(null);
          toast.error(
            result.reason === "permission"
              ? tConfirm("blockedPermission")
              : result.reason === "no-conversation"
                ? tConfirm("blockedNoConversation")
                : result.reason === "draft-mismatch"
                  ? tConfirm("blockedMismatch")
                  : tConfirm("blockedInvalidFile"),
          );
          return;
        }

        case "busy": {
          toast.error(tConfirm("busy"));
          return;
        }
      }
    },
    [discardProofDraft, refreshDeals, t, tConfirm],
  );

  /**
   * Run the delivery the operator just confirmed.
   *
   * `skipProof` is the closed-window escape hatch: the image cannot
   * cross a shut 24-hour window, but the final `remesa_completada`
   * template can, so the remittance is still delivered — just without
   * the screenshot. Measured at roughly 1 delivery in 108; blocking
   * those would strand real deliveries on the board.
   */
  const runDelivery = useCallback(
    async (deal: Deal, skipProof: boolean, expectsProof: boolean) => {
      const draft = proofDrafts.get(deal.id) ?? null;
      setDeliveringId(deal.id);

      const deps: DeliveryDeps = {
        canSend: () => canCreateDeals,
        isWindowOpen,
        uploadProof: (file, uploadName) =>
          // Re-wrapped under a generic name: `buildMediaPath` keeps the
          // filename in the object path, and `chat-media` is public, so
          // the original "captura-juan-perez.png" would publish the
          // customer's name in a URL.
          uploadAccountMedia(
            CHAT_MEDIA_BUCKET,
            new File([file], uploadName, { type: file.type }),
          ),
        sendProof: async ({ conversationId, mediaUrl, caption }) => {
          const res = await fetch("/api/whatsapp/send", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              conversation_id: conversationId,
              message_type: "image",
              media_url: mediaUrl,
              content_text: caption || undefined,
            }),
          });
          const body = await res.json().catch(() => ({}));

          if (res.ok) {
            return { ok: true, wamid: body?.whatsapp_message_id };
          }

          const message = body?.error || `HTTP ${res.status}`;
          // `db_error` with a wamid means Meta ACCEPTED the image and
          // WaCRM then failed to save the row. An HTTP error that is
          // really a delivered message — the one case where "it
          // failed, try again" would send the customer a duplicate.
          if (body?.code === "db_error" && body?.whatsapp_message_id) {
            return {
              ok: false,
              outcome: "sent-not-recorded",
              message,
              wamid: body.whatsapp_message_id as string,
            };
          }
          return { ok: false, outcome: "not-sent", message };
        },
        readStage: async (dealId) => {
          const { data, error } = await supabase
            .from("deals")
            .select("stage_id")
            .eq("id", dealId)
            .maybeSingle();
          // A failed read is treated as "don't know" and aborts the
          // send: better a retry than an image sent into a deal
          // somebody else already closed.
          if (error || !data) return null;
          return (data as { stage_id: string }).stage_id;
        },
        discardUpload: async (path) => {
          await deleteAccountMedia(CHAT_MEDIA_BUCKET, path);
        },
        moveToDelivered: (id) => persistStage(id, DELIVERED_STAGE_ID),
      };

      let result: DeliveryResult;
      try {
        result = await deliverDeal(
          {
            dealId: deal.id,
            conversationId: deal.conversation_id,
            draft: draftBelongsTo(draft, deal.id) ? draft : null,
            skipProof,
            expectsProof,
          },
          deps,
        );
      } catch (err) {
        result = {
          status: "failed",
          phase: "send",
          message: err instanceof Error ? err.message : String(err),
        };
      } finally {
        setDeliveringId(null);
      }

      handleDeliveryResult(deal, result);
    },
    [
      proofDrafts,
      canCreateDeals,
      supabase,
      isWindowOpen,
      persistStage,
      handleDeliveryResult,
    ],
  );

  const handleAddDeal = useCallback(
    (stageId?: string) => {
      setEditingDeal(null);
      setDefaultStageId(stageId ?? stages[0]?.id ?? "");
      setDealFormOpen(true);
    },
    [stages],
  );

  const handleEditDeal = useCallback((deal: Deal) => {
    setEditingDeal(deal);
    setDefaultStageId(deal.stage_id);
    setDealFormOpen(true);
  }, []);

  async function handleCreatePipeline() {
    const name = newPipelineName.trim();
    if (!name) return;
    setCreating(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();
    const user = session?.user;
    if (!user) {
      setCreating(false);
      return;
    }
    // pipelines.account_id is NOT NULL post-017 with no DB default.
    if (!accountId) {
      toast.error(t("toastNotLinkedToAccount"));
      setCreating(false);
      return;
    }

    const { data: pipeline, error } = await supabase
      .from("pipelines")
      .insert({ user_id: user.id, account_id: accountId, name })
      .select()
      .single();

    if (error || !pipeline) {
      toast.error(t("toastFailedCreatePipeline"));
      setCreating(false);
      return;
    }

    const stagesPayload = SPEC_DEFAULT_STAGES.map((s) => ({
      pipeline_id: pipeline.id,
      name: s.name,
      color: s.color,
      position: s.position,
    }));
    await supabase.from("pipeline_stages").insert(stagesPayload);

    setNewPipelineName("");
    setNewPipelineOpen(false);
    setSelectedPipelineId(pipeline.id);
    await refreshPipelines();
    setCreating(false);
    toast.success(t("toastPipelineCreated"));
  }

  const selectedPipeline = pipelines.find((p) => p.id === selectedPipelineId);

  // Which cards show the paperclip. A Set rather than the Map itself so
  // the board re-renders on membership changes, not on every keystroke
  // in a note.
  const proofDealIds = useMemo(
    () => new Set(proofDrafts.keys()),
    [proofDrafts],
  );

  // The draft behind the open confirmation dialog, if any.
  const promptDraft = prompt ? proofDrafts.get(prompt.deal.id) ?? null : null;


  if (loading) {
    return (
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div className="h-8 w-48 animate-pulse rounded bg-muted" />
          <div className="h-9 w-28 animate-pulse rounded-lg bg-muted" />
        </div>
        <div className="flex gap-3">
          {[1, 2, 3, 4, 5].map((i) => (
            <div key={i} className="h-96 w-72 animate-pulse rounded-xl bg-muted/50" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          {/* Pipeline selector dropdown */}
          <DropdownMenu>
            <DropdownMenuTrigger
              className="inline-flex items-center gap-2 rounded-lg border border-border bg-card px-3 py-2 text-sm text-foreground hover:bg-muted transition-colors data-[popup-open]:bg-muted"
            >
              <GitBranch className="h-4 w-4 text-primary" />
              <span className="font-semibold">
                {selectedPipeline?.name ?? t("selectPipeline")}
              </span>
              <ChevronDown className="h-4 w-4 text-muted-foreground" />
            </DropdownMenuTrigger>
            <DropdownMenuContent
              align="start"
              className="w-64 border-border bg-popover text-popover-foreground"
            >
              {pipelines.length === 0 && (
                <DropdownMenuItem disabled className="text-muted-foreground">
                  {t("noPipelinesYet")}
                </DropdownMenuItem>
              )}
              {pipelines.map((p) => (
                <DropdownMenuItem
                  key={p.id}
                  onClick={() => setSelectedPipelineId(p.id)}
                  className={
                    p.id === selectedPipelineId
                      ? "text-primary"
                      : "text-popover-foreground"
                  }
                >
                  <GitBranch className="mr-2 h-3.5 w-3.5" />
                  {p.name}
                </DropdownMenuItem>
              ))}
              <DropdownMenuSeparator className="bg-border" />
              {selectedPipeline && (
                <DropdownMenuItem
                  onClick={() => setSettingsOpen(true)}
                  className="text-popover-foreground"
                >
                  <Settings className="mr-2 h-3.5 w-3.5" />
                  {t("managePipelines")}
                </DropdownMenuItem>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>

        <div className="flex items-center gap-2">
          <GatedButton
            variant="outline"
            canAct={canEditSettings}
            gateReason="create pipelines"
            onClick={() => setNewPipelineOpen(true)}
            className="border-border bg-card text-foreground hover:bg-muted"
          >
            <Plus className="mr-1 h-4 w-4" />
            {t("addPipeline")}
          </GatedButton>
          <GatedButton
            canAct={canCreateDeals}
            gateReason="create deals"
            disabled={!selectedPipelineId || stages.length === 0}
            onClick={() => handleAddDeal()}
            className="bg-primary text-primary-foreground hover:bg-primary/90"
          >
            <Plus className="mr-1 h-4 w-4" />
            {t("addDeal")}
          </GatedButton>
        </div>
      </div>

      {/* Board */}
      {pipelines.length === 0 ? (
        <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-border py-20">
          <GitBranch className="h-12 w-12 text-muted-foreground" />
          <h3 className="mt-4 text-lg font-medium text-foreground">
            {t("noPipelinesYet")}
          </h3>
          <p className="mt-2 text-sm text-muted-foreground">
            {t("createToStartTracking")}
          </p>
          <GatedButton
            canAct={canEditSettings}
            gateReason="create pipelines"
            onClick={() => setNewPipelineOpen(true)}
            className="mt-4 bg-primary text-primary-foreground hover:bg-primary/90"
          >
            <Plus className="mr-1 h-4 w-4" />
            {t("createPipeline")}
          </GatedButton>
        </div>
      ) : (
        <>
          <PipelineAnalytics stages={stages} deals={deals} />
          <PipelineBoard
            stages={stages}
            deals={deals}
            onDealMoved={handleDealMoved}
            onAddDeal={handleAddDeal}
            onEditDeal={handleEditDeal}
            dealsWithProof={proofDealIds}
          />
        </>
      )}

      {/* New Pipeline Dialog */}
      <Dialog open={newPipelineOpen} onOpenChange={setNewPipelineOpen}>
        <DialogContent className="sm:max-w-sm bg-popover border-border">
          <DialogHeader>
            <DialogTitle className="text-popover-foreground">{t("newPipeline")}</DialogTitle>
          </DialogHeader>
          <div className="py-2">
            <Label className="text-muted-foreground">{t("pipelineName")}</Label>
            <Input
              value={newPipelineName}
              onChange={(e) => setNewPipelineName(e.target.value)}
              placeholder={t("pipelineNamePlaceholder")}
              className="mt-2 bg-muted border-border text-foreground"
              onKeyDown={(e) => {
                if (e.key === "Enter") handleCreatePipeline();
              }}
            />
            <p className="mt-2 text-xs text-muted-foreground">
              {t("defaultStagesDesc")}
            </p>
          </div>
          <DialogFooter className="bg-popover/50 border-border">
            <Button
              variant="outline"
              onClick={() => setNewPipelineOpen(false)}
              className="border-border text-muted-foreground hover:bg-muted"
            >
              {t("cancel")}
            </Button>
            <Button
              onClick={handleCreatePipeline}
              disabled={creating || !newPipelineName.trim()}
              className="bg-primary text-primary-foreground hover:bg-primary/90"
            >
              {creating ? t("creating") : t("createPipelineBtn")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Pipeline Settings */}
      {selectedPipeline && (
        <PipelineSettings
          open={settingsOpen}
          onOpenChange={setSettingsOpen}
          pipeline={selectedPipeline}
          stages={stages}
          onPipelinesChanged={refreshPipelines}
          onStagesChanged={refreshStages}
          onCreateNewPipeline={() => {
            setSettingsOpen(false);
            setNewPipelineOpen(true);
          }}
        />
      )}

      {/* Deal Form (Sheet) */}
      <DealForm
        open={dealFormOpen}
        onOpenChange={setDealFormOpen}
        deal={editingDeal}
        pipelineId={selectedPipelineId}
        stages={stages}
        defaultStageId={defaultStageId}
        onSaved={refreshDeals}
        proofDraft={editingDeal ? proofDrafts.get(editingDeal.id) ?? null : null}
        onProofFileAccepted={handleProofFileAccepted}
        onProofRejected={handleProofRejected}
        onProofCaptionChange={handleProofCaptionChange}
        onProofClear={discardProofDraft}
        canSendMessages={canCreateDeals}
        proofBusy={!!editingDeal && deliveringId === editingDeal.id}
      />

      {/* Delivery confirmation. Only ever opened for a deal that has a
          proof prepared — a deal without one goes straight through
          `handleDealMoved` as it always did. */}
      <Dialog
        open={!!prompt}
        onOpenChange={(next) => {
          // Never dismissable mid-send: closing would strand the
          // operator without the retry for a proof already delivered.
          if (!next && !deliveringId) setPrompt(null);
        }}
      >
        <DialogContent className="sm:max-w-md bg-popover border-border">
          <DialogHeader>
            <DialogTitle className="text-popover-foreground">
              {prompt?.mode === "window-closed"
                ? tConfirm("closedTitle")
                : prompt?.mode === "stage-failed"
                  ? tConfirm("failStage")
                  : prompt?.mode === "sent-not-recorded"
                    ? tConfirm("sentNotRecordedTitle")
                    : prompt?.mode === "unconfirmed"
                      ? tConfirm("unconfirmedTitle")
                      : tConfirm("title")}
            </DialogTitle>
          </DialogHeader>

          {prompt && (
            <div className="space-y-3 py-1">
              {prompt.mode === "confirm" && (
                <>
                  <div className="flex items-start gap-3">
                    {promptDraft?.previewUrl && (
                      // A blob: URL for a file that has not been
                      // uploaded — next/image cannot handle it.
                      // eslint-disable-next-line @next/next/no-img-element
                      <img
                        src={promptDraft.previewUrl}
                        alt={tProof("previewAlt")}
                        className="h-20 w-20 shrink-0 rounded-md border border-border object-cover"
                      />
                    )}
                    <div className="min-w-0 flex-1 text-sm">
                      <p className="font-medium text-foreground">
                        {prompt.deal.title}
                      </p>
                      {promptDraft?.caption.trim() && (
                        <p className="mt-1 whitespace-pre-wrap break-words text-xs text-muted-foreground">
                          {promptDraft.caption.trim()}
                        </p>
                      )}
                    </div>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {tConfirm("body")}
                  </p>
                </>
              )}

              {prompt.mode === "window-closed" && (
                <p className="whitespace-pre-line text-xs leading-relaxed text-muted-foreground">
                  {tConfirm("closedBody")}
                </p>
              )}

              {prompt.mode === "stage-failed" && (
                <p className="text-xs leading-relaxed text-muted-foreground">
                  {prompt.message}
                </p>
              )}

              {prompt.mode === "sent-not-recorded" && (
                <p className="whitespace-pre-line rounded-md bg-amber-500/10 px-2 py-1.5 text-xs leading-relaxed text-amber-500">
                  {tConfirm("sentNotRecordedBody")}
                </p>
              )}

              {prompt.mode === "unconfirmed" && (
                <p className="whitespace-pre-line rounded-md bg-amber-500/10 px-2 py-1.5 text-xs leading-relaxed text-amber-500">
                  {tConfirm("unconfirmedBody")}
                </p>
              )}
            </div>
          )}

          <DialogFooter className="bg-popover/50 border-border">
            <Button
              variant="outline"
              disabled={!!deliveringId}
              onClick={() => setPrompt(null)}
              className="border-border text-muted-foreground hover:bg-muted"
            >
              {tConfirm("cancel")}
            </Button>
            <Button
              disabled={!!deliveringId}
              onClick={() => {
                if (!prompt) return;
                void runDelivery(
                  prompt.deal,
                  prompt.mode === "window-closed",
                  prompt.mode === "confirm" || prompt.mode === "window-closed",
                );
              }}
              className="bg-primary text-primary-foreground hover:bg-primary/90"
            >
              {deliveringId
                ? tConfirm("sending")
                : prompt?.mode === "window-closed"
                  ? tConfirm("closedConfirm")
                  : prompt?.mode === "stage-failed"
                    ? tConfirm("retryStage")
                    : prompt?.mode === "sent-not-recorded"
                      ? tConfirm("retryStageOnly")
                      : prompt?.mode === "unconfirmed"
                        ? tConfirm("retrySend")
                        : tConfirm("confirm")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
