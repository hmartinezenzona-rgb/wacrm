"use client";

import { useState, useEffect, useCallback, useMemo, useRef } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  CONVERSATION_SELECT,
  matchesContactFilters,
  normalizeConversations,
  type RawConversation,
} from "@/lib/inbox/conversations";
import { prefetchConversationOperations } from "@/lib/remittance-operations/panel-prefetch";
import type { EffectiveStatus } from "@/lib/remittance-operations/effective-status";
import { fetchBoard } from "@/lib/tablero/fetch";
import type { BoardOperation } from "@/lib/tablero/board";
import { openOperationStatusByConversation } from "@/lib/inbox/open-operation-status";
import { statusPillClass, statusTone } from "@/lib/status-tone";
import { cn } from "@/lib/utils";
import type { Conversation, ConversationStatus, Tag } from "@/types";
import { Search, ChevronDown, X, Pin } from "lucide-react";
import { OwnershipIcon } from "./ownership-icon";
import {
  resolveConversationOwnership,
  type ConversationOwnership,
} from "@/lib/inbox/conversation-ownership";
import { toast } from "sonner";
import { formatDistanceToNow } from "date-fns";
import { useTranslations } from "next-intl";
import { ContactAvatar } from "@/components/contacts/contact-avatar";
import { Input } from "@/components/ui/input";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Checkbox } from "@/components/ui/checkbox";
import {
  alternarSeleccion,
  etiquetaSeleccion,
  laAbiertaSeVa,
  parcheOcultar,
  parcheRestaurar,
  reconciliarSeleccion,
  textoConfirmacion,
  textoQuitadas,
} from "@/lib/inbox/selection";

interface ConversationListProps {
  activeConversationId: string | null;
  onSelect: (conversation: Conversation) => void;
  conversations: Conversation[];
  onConversationsLoaded: (conversations: Conversation[]) => void;
  /**
   * Increment to force the fetch effect below to refire. The parent
   * bumps this on realtime reconnect / tab visibility → visible so the
   * list catches up on any events sent while the WS was disconnected
   * or the tab was throttled. Optional so existing callers keep working.
   */
  resyncToken?: number;
  /**
   * Se avisa cuando el usuario quita conversaciones del inbox. El padre lo
   * necesita para soltar la que tuviera abierta: si no, el panel de la derecha
   * se queda enseñando un hilo que ya no está en la lista.
   */
  onConversationsHidden?: (ids: string[]) => void;
  /**
   * B1.5(b): bulk "marcar todas como leídas". Optional so existing
   * callers keep working; when omitted the button doesn't render. The
   * parent (inbox page) owns the DB write's side effects that don't
   * belong here — stopping the chat notification sound and gating it
   * against ringing again for messages already marked read.
   */
  onMarkAllRead?: () => void;
}

const STATUS_COLORS: Record<ConversationStatus, string> = {
  open: "bg-primary",
  pending: "bg-amber-500",
  closed: "bg-muted-foreground",
};



type InboxFilter = ConversationStatus | "all" | "unread";

/** Filtro por quién lleva el hilo. `todos` no filtra nada. */
type FiltroPropiedad = "todos" | ConversationOwnership;

const FILTROS_PROPIEDAD: { valor: FiltroPropiedad; etiqueta: string }[] = [
  { valor: "todos", etiqueta: "Todos" },
  { valor: "bot", etiqueta: "Bot" },
  { valor: "human", etiqueta: "Humano" },
  { valor: "paused", etiqueta: "IA pausada" },
];

/**
 * Replica el ORDER BY de la consulta (pinned_at DESC NULLS LAST,
 * last_message_at DESC) en el punto donde se pinta. Un solo lugar:
 * la lista se reordena en cada render aunque el array se haya mutado
 * en vivo sin refetch.
 */
function ordenarConversaciones(a: Conversation, b: Conversation) {
  // Fijados siempre primero
  const fa = !!a.pinned_at,
    fb = !!b.pinned_at;
  if (fa !== fb) return fa ? -1 : 1;

  // Entre fijados, el fijado más recientemente arriba
  if (fa && fb) {
    const d =
      new Date(b.pinned_at!).getTime() - new Date(a.pinned_at!).getTime();
    if (d !== 0) return d;
  }

  // El resto, por último mensaje descendente. Sin fecha, al final.
  const ta = a.last_message_at ? new Date(a.last_message_at).getTime() : 0;
  const tb = b.last_message_at ? new Date(b.last_message_at).getTime() : 0;
  return tb - ta;
}

/** Ventana de actividad reciente que la bandeja carga por defecto. */
const RECENT_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Añade las conversaciones con una operación abierta que el filtro dejó fuera.
 * Recibe los ids ya leídos del tablero: la petición del RPC no se repite.
 */
async function withOpenOperationConversations(
  supabase: ReturnType<typeof createClient>,
  rows: RawConversation[],
  openOperationConversationIds: string[],
): Promise<RawConversation[]> {
  const have = new Set(rows.map((r) => r.id));
  const missing = openOperationConversationIds.filter((id) => !have.has(id));
  if (missing.length === 0) return rows;
  const { data } = await supabase
    .from("conversations")
    .select(CONVERSATION_SELECT)
    .in("id", missing)
    .is("deleted_at", null);
  return [...rows, ...((data ?? []) as RawConversation[])];
}

export function ConversationList({
  activeConversationId,
  onSelect,
  conversations,
  onConversationsLoaded,
  resyncToken = 0,
  onConversationsHidden,
  onMarkAllRead,
}: ConversationListProps) {
  const t = useTranslations("Inbox.conversationList");
  // La bandeja enseña la actividad reciente; el historial completo queda a un
  // toque ("Ver todas"). Nunca se esconden fijadas, no leídas ni conversaciones
  // con una operación abierta: esas entran aunque no hayan escrito en semanas.
  const [showAll, setShowAll] = useState(false);
  
  const FILTER_OPTIONS: { label: string; value: InboxFilter }[] = useMemo(() => [
    { label: t("filterAll"), value: "all" },
    { label: t("filterUnread"), value: "unread" },
    { label: t("filterOpen"), value: "open" },
    { label: t("filterPending"), value: "pending" },
    { label: t("filterClosed"), value: "closed" },
  ], [t]);

  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<InboxFilter>("all");
  // Quién lleva el hilo. Se resuelve del estado ya cargado: sin consultas.
  const [filtroPropiedad, setFiltroPropiedad] = useState<FiltroPropiedad>("todos");
  /**
   * userId -> nombre, para el tooltip del icono humano. UNA consulta para todo
   * el equipo, no una por conversación. `assigned_agent_id` no tiene clave
   * foránea, así que PostgREST no puede traerlo embebido en el select.
   */
  const [nombresPorAgente, setNombresPorAgente] = useState<
    ReadonlyMap<string, string>
  >(new Map());
  const [loading, setLoading] = useState(true);
  /**
   * conversationId -> status of its most relevant OPEN operation (chip on the
   * row). Loaded with ONE board RPC for the whole list, not one request per
   * row: `remittance_operations` has no foreign key to `conversations`, so it
   * cannot be embedded in CONVERSATION_SELECT without a migration.
   */
  const [operationStatuses, setOperationStatuses] = useState<
    ReadonlyMap<string, EffectiveStatus>
  >(new Map());
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  // Explícito y no derivado de `selectedIds.size > 0`: así el modo se queda
  // activo (casillas visibles en toda la lista) aunque el usuario destilde la
  // última fila a mano, y sólo se sale con «Cancelar» o al quitar del inbox.
  const [modoSeleccion, setModoSeleccion] = useState(false);
  // Contact-based filters (issue #272). Tags use OR logic (a conversation
  // matches if its contact carries any selected tag), consistent with
  // Broadcast audience filtering. Company is an exact match on the field.
  const [tags, setTags] = useState<Tag[]>([]);
  const [selectedTagIds, setSelectedTagIds] = useState<string[]>([]);
  const [selectedCompany, setSelectedCompany] = useState<string | null>(null);

  // Keep the latest callback in a ref so the fetch effect below can
  // have a stable, empty-dep identity. Previously the fetch useCallback
  // depended on `onConversationsLoaded`, which depends on the parent's
  // `deepLinkConvId` — so every URL change (including one the parent
  // triggered via router.replace after a click) caused a fresh
  // conversations fetch. That extra refetch was the trigger for the
  // deep-link auto-select running a second time and wiping the active
  // thread's messages.
  // Mutation lives in an effect (not render) per React 19's refs rule;
  // the fetch runs once on mount so it's fine to read the slightly
  // older value — the very next render updates the ref for any
  // subsequent async completion.
  const onConversationsLoadedRef = useRef(onConversationsLoaded);
  useEffect(() => {
    onConversationsLoadedRef.current = onConversationsLoaded;
  });

  // Buscar tiene que alcanzar todo el historial: con texto en el buscador se
  // carga la lista completa aunque el filtro de recencia esté activo.
  const loadAll = showAll || search.trim().length > 0;

  // El tablero se pide UNA vez por carga: los chips y la recuperación de
  // conversaciones con operación abierta comparten la misma petición. La
  // ventana es corta (5 s) para que un refresco por realtime siga leyendo
  // datos frescos.
  const boardPromiseRef = useRef<{ at: number; promise: Promise<BoardOperation[]> } | null>(null);
  const boardForLoad = useCallback((): Promise<BoardOperation[]> => {
    const now = Date.now();
    const cached = boardPromiseRef.current;
    if (cached && now - cached.at < 5000) return cached.promise;
    const promise = fetchBoard(createClient()).catch(() => [] as BoardOperation[]);
    boardPromiseRef.current = { at: now, promise };
    return promise;
  }, []);

  /** Un cambio real o un resync deben leer el tablero de nuevo. */
  const invalidateBoard = useCallback(() => {
    boardPromiseRef.current = null;
  }, []);

  const fetchConversations = useCallback(async (): Promise<Conversation[] | null> => {
    const supabase = createClient();
    let query = supabase
      .from("conversations")
      .select(CONVERSATION_SELECT)
      .is("deleted_at", null)
      .order("pinned_at", { ascending: false, nullsFirst: false })
      .order("last_message_at", { ascending: false });

    if (!loadAll) {
      const cutoff = new Date(Date.now() - RECENT_WINDOW_MS).toISOString();
      query = query.or(`last_message_at.gte.${cutoff},pinned_at.not.is.null,unread_count.gt.0`);
    }

    const { data, error } = await query;

    if (error) {
      // Supabase errors have non-enumerable properties — log fields explicitly
      console.error("Failed to fetch conversations:", {
        message: error.message,
        details: error.details,
        hint: error.hint,
        code: error.code,
      });
      return null;
    }
    const rows = (data ?? []) as RawConversation[];
    if (loadAll) return normalizeConversations(rows);
    const board = await boardForLoad();
    return normalizeConversations(
      await withOpenOperationConversations(
        supabase,
        rows,
        board.map((o) => o.conversationId),
      ),
    );
  }, [loadAll, boardForLoad]);

  useEffect(() => {
    let cancelado = false;
    (async () => {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("profiles")
        .select("user_id, full_name");
      if (cancelado) return;
      if (error) {
        // Sin nombres el icono sigue funcionando: dirá «una persona».
        console.error("No se pudieron cargar los nombres del equipo:", {
          message: error.message,
          code: error.code,
        });
        return;
      }
      const m = new Map<string, string>();
      for (const p of data ?? []) {
        const id = (p as { user_id?: string }).user_id;
        const nombre = (p as { full_name?: string | null }).full_name;
        if (id && nombre) m.set(id, nombre);
      }
      setNombresPorAgente(m);
    })();
    return () => {
      cancelado = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      const convs = await fetchConversations();
      if (cancelled) return;
      if (convs) onConversationsLoadedRef.current(convs);
      setLoading(false);
    })();

    return () => {
      cancelled = true;
    };
    // `resyncToken` is included so the parent can force a refetch when
    // the realtime channel reconnects or the tab regains focus — catches
    // up on any events sent while the WS was disconnected or throttled.
  }, [fetchConversations, resyncToken]);

  // Chips de estado de la operación abierta. Un fallo deja los chips como
  // estaban (o sin chips): la lista nunca depende de ellos.
  const loadOperationStatuses = useCallback(async () => {
    try {
      const board = await boardForLoad();
      setOperationStatuses(
        openOperationStatusByConversation(
          board.map((o) => ({
            conversationId: o.conversationId,
            status: o.status,
            beneficiariesComplete: o.beneficiariesComplete,
            createdAt: o.createdAt,
          })),
        ),
      );
    } catch (error) {
      console.error("Failed to load operation statuses:", error);
    }
  }, [boardForLoad]);

  // `resyncToken` también recarga los chips (reconexión / pestaña visible).
  useEffect(() => {
    invalidateBoard();
    (async () => {
      await loadOperationStatuses();
    })();
  }, [invalidateBoard, loadOperationStatuses, resyncToken]);

  // Tiempo real: cualquier cambio en `remittance_operations` (la tabla está
  // en la publicación supabase_realtime desde la migración 181; RLS la limita
  // a la cuenta) vuelve a pedir el tablero. Debounce porque un solo comando
  // dispara varios UPDATE seguidos.
  useEffect(() => {
    const supabase = createClient();
    let timer: ReturnType<typeof setTimeout> | null = null;
    const schedule = () => {
      invalidateBoard();
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => void loadOperationStatuses(), 800);
    };
    const channel = supabase
      .channel(`inbox-list-operations-${Math.random().toString(36).slice(2)}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "remittance_operations" },
        schedule,
      )
      .subscribe();
    return () => {
      if (timer) clearTimeout(timer);
      supabase.removeChannel(channel);
    };
  }, [loadOperationStatuses]);

  /** Aplica pinned_at/deleted_at y refresca la lista. Nunca borra la fila. */
  const applyConversationUpdate = useCallback(
    async (
      id: string,
      patch: { pinned_at?: string | null; deleted_at?: string | null },
    ) => {
      const supabase = createClient();
      const { error } = await supabase
        .from("conversations")
        .update(patch)
        .eq("id", id);
      if (error) {
        console.error("Failed to update conversation:", {
          message: error.message,
          details: error.details,
          hint: error.hint,
          code: error.code,
        });
        return false;
      }
      const convs = await fetchConversations();
      if (convs) onConversationsLoadedRef.current(convs);
      return true;
    },
    [fetchConversations],
  );

  const handlePin = useCallback(
    (id: string) =>
      void applyConversationUpdate(id, { pinned_at: new Date().toISOString() }),
    [applyConversationUpdate],
  );

  const handleUnpin = useCallback(
    (id: string) => void applyConversationUpdate(id, { pinned_at: null }),
    [applyConversationUpdate],
  );

  const handleDelete = useCallback(
    (id: string, name: string) => {
      if (
        !window.confirm(
          `¿Ocultar el chat con ${name}? El historial se conserva y el chat reaparecerá si el cliente escribe.`,
        )
      )
        return;
      void (async () => {
        const ok = await applyConversationUpdate(id, {
          deleted_at: new Date().toISOString(),
        });
        if (ok) {
          // Si era justo la conversación abierta, el padre debe soltarla:
          // si no, el panel de la derecha se queda enseñando un hilo que ya
          // no está en la lista.
          if (laAbiertaSeVa(activeConversationId, [id])) {
            onConversationsHidden?.([id]);
          }
          toast("Chat oculto", {
            description: `El chat con ${name} se ocultó de la lista.`,
            action: {
              label: "Deshacer",
              onClick: () =>
                void applyConversationUpdate(id, { deleted_at: null }),
            },
          });
        }
      })();
    },
    [applyConversationUpdate, activeConversationId, onConversationsHidden],
  );

  const toggleSelect = useCallback((id: string) => {
    setSelectedIds((prev) => {
      const next = alternarSeleccion(prev, id);
      // Entra en modo selección al marcar la primera fila. Nunca lo apaga
      // aquí: destildar la última se queda en modo hasta «Cancelar», igual
      // que la entrada por pulsación larga.
      if (next.size > 0) setModoSeleccion(true);
      return next;
    });
  }, []);

  /** Entrada táctil: pulsación larga sobre una fila, sin necesidad de hover. */
  const handleLongPress = useCallback(
    (id: string) => {
      setModoSeleccion(true);
      toggleSelect(id);
    },
    [toggleSelect],
  );

  const clearSelection = useCallback(() => {
    setSelectedIds(new Set());
    setModoSeleccion(false);
  }, []);

  /** Deshace un «quitar del inbox» en bloque: UNA sola escritura, no N. */
  const restaurarSeleccionadas = useCallback(
    async (ids: string[]) => {
      const supabase = createClient();
      const { error } = await supabase
        .from("conversations")
        .update(parcheRestaurar())
        .in("id", ids);
      if (error) {
        console.error("No se pudieron restaurar las conversaciones:", {
          message: error.message,
          details: error.details,
          hint: error.hint,
          code: error.code,
        });
        return;
      }
      const convs = await fetchConversations();
      if (convs) onConversationsLoadedRef.current(convs);
    },
    [fetchConversations],
  );

  // Tag definitions for the filter picker — loaded once so labels/colours
  // stay stable regardless of which conversations happen to be loaded.
  useEffect(() => {
    const supabase = createClient();
    let cancelled = false;
    (async () => {
      const { data } = await supabase.from("tags").select("*").order("name");
      if (!cancelled && data) setTags(data as Tag[]);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // Company options are derived from the loaded conversations — there's no
  // separate companies table, and only companies with a live conversation
  // are worth offering as an inbox filter.
  const companies = useMemo(() => {
    const set = new Set<string>();
    for (const c of conversations) {
      const co = c.contact?.company?.trim();
      if (co) set.add(co);
    }
    return Array.from(set).sort((a, b) => a.localeCompare(b));
  }, [conversations]);

  const tagsById = useMemo(() => {
    const m = new Map<string, Tag>();
    for (const t of tags) m.set(t.id, t);
    return m;
  }, [tags]);

  const filtered = useMemo(() => {
    let result = conversations;

    if (filter === "unread") {
      result = result.filter((c) => c.unread_count > 0);
    } else if (filter !== "all") {
      result = result.filter((c) => c.status === filter);
    }

    if (filtroPropiedad !== "todos") {
      result = result.filter(
        (c) => resolveConversationOwnership(c).ownership === filtroPropiedad,
      );
    }

    // Contact-based filters (tags via OR logic, exact company match).
    if (selectedTagIds.length > 0 || selectedCompany !== null) {
      result = result.filter((c) =>
        matchesContactFilters(c, {
          tagIds: selectedTagIds,
          company: selectedCompany,
        })
      );
    }

    if (search.trim()) {
      const q = search.toLowerCase();
      result = result.filter((c) => {
        const name = c.contact?.name?.toLowerCase() ?? "";
        const phone = c.contact?.phone?.toLowerCase() ?? "";
        const lastMsg = c.last_message_text?.toLowerCase() ?? "";
        return name.includes(q) || phone.includes(q) || lastMsg.includes(q);
      });
    }

    return result.slice().sort(ordenarConversaciones);
  }, [conversations, filter, filtroPropiedad, search, selectedTagIds, selectedCompany]);

  /**
   * La selección que de verdad cuenta: lo guardado menos lo que ya no está
   * visible. Se deriva en el render y no en un efecto —la lista se refresca
   * sola (realtime, o el propio refetch tras ocultar), y una conversación
   * seleccionada puede desaparecer por debajo; derivarlo evita además el
   * setState-en-efecto que este proyecto no admite (react-hooks/set-state-in-effect).
   */
  const selectedVisibleIds = useMemo(
    () => reconciliarSeleccion(selectedIds, filtered.map((c) => c.id)),
    [selectedIds, filtered],
  );

  /**
   * Quita del inbox en UNA sola escritura (`.in()`), no N peticiones
   * secuenciales. No borra: escribe `deleted_at`, lo mismo que ya hacía el
   * quitado individual. Actúa sobre lo VISIBLE seleccionado, no sobre el
   * crudo: si algo seleccionado ya desapareció de la lista, no se toca.
   */
  const handleQuitarSeleccionadas = useCallback(() => {
    const ids = [...selectedVisibleIds];
    if (ids.length === 0) return;
    if (!window.confirm(textoConfirmacion(ids.length))) return;
    void (async () => {
      const supabase = createClient();
      const { error } = await supabase
        .from("conversations")
        .update(parcheOcultar())
        .in("id", ids);
      if (error) {
        console.error("No se pudieron quitar las conversaciones:", {
          message: error.message,
          details: error.details,
          hint: error.hint,
          code: error.code,
        });
        return;
      }
      if (laAbiertaSeVa(activeConversationId, ids)) {
        onConversationsHidden?.(ids);
      }
      const convs = await fetchConversations();
      if (convs) onConversationsLoadedRef.current(convs);
      clearSelection();
      toast(textoQuitadas(ids.length), {
        description: "El historial se conserva.",
        action: {
          label: "Deshacer",
          onClick: () => void restaurarSeleccionadas(ids),
        },
      });
    })();
  }, [
    selectedVisibleIds,
    activeConversationId,
    onConversationsHidden,
    fetchConversations,
    clearSelection,
    restaurarSeleccionadas,
  ]);

  const toggleTag = useCallback((id: string) => {
    setSelectedTagIds((prev) =>
      prev.includes(id) ? prev.filter((t) => t !== id) : [...prev, id]
    );
  }, []);

  const clearContactFilters = useCallback(() => {
    setSelectedTagIds([]);
    setSelectedCompany(null);
  }, []);

  const hasContactFilters = selectedTagIds.length > 0 || selectedCompany !== null;
  const hasUnreadConversations = conversations.some((c) => c.unread_count > 0);

  const handleSearchChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setSearch(e.target.value);
    },
    []
  );

  const handleSelect = useCallback(
    (conv: Conversation) => {
      onSelect(conv);
    },
    [onSelect]
  );

  const activeFilter = FILTER_OPTIONS.find((o) => o.value === filter);

  return (
    // w-full on mobile so the list occupies the whole viewport when it's
    // the single pane showing; fixed 320px on desktop where it shares the
    // row with the thread + contact sidebar.
    // `min-w-0` + `overflow-x-hidden`: the row must be able to shrink to
    // the viewport; a long chip or a wide label must never widen the pane
    // past the screen (it showed cut on phones, 2026-10-24).
    <div className="flex h-full w-full min-w-0 flex-col overflow-x-hidden border-r border-border bg-card lg:w-80">
      {/* Search + Filter */}
      <div className="space-y-2 border-b border-border p-3">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={handleSearchChange}
            placeholder={t("searchPlaceholder")}
            className="border-border bg-muted pl-9 text-sm text-foreground placeholder-muted-foreground focus:border-primary/50"
          />
        </div>

        <div className="flex flex-wrap items-center gap-1">
          <DropdownMenu>
            <DropdownMenuTrigger className="inline-flex items-center justify-center h-7 gap-1 px-2 text-xs text-muted-foreground hover:text-foreground rounded-md hover:bg-muted">
                {activeFilter?.label ?? t("filterAll")}
                <ChevronDown className="h-3 w-3" />
            </DropdownMenuTrigger>
            <DropdownMenuContent
              align="start"
              className="border-border bg-popover"
            >
              {FILTER_OPTIONS.map((opt) => (
                <DropdownMenuItem
                  key={opt.value}
                  onClick={() => setFilter(opt.value)}
                  className={cn(
                    "text-sm",
                    filter === opt.value
                      ? "text-primary"
                      : "text-popover-foreground"
                  )}
                >
                  {opt.label}
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>

          {/* Quién atiende: se lee del estado de cada hilo, no del historial. */}
          <div className="flex items-center gap-1">
            {FILTROS_PROPIEDAD.map((f) => (
              <button
                key={f.valor}
                type="button"
                onClick={() => setFiltroPropiedad(f.valor)}
                className={cn(
                  "rounded-full border px-2 py-0.5 text-[11px] transition-colors",
                  filtroPropiedad === f.valor
                    ? "border-primary/40 bg-primary/15 text-primary"
                    : "border-border text-muted-foreground hover:bg-muted",
                )}
              >
                {f.etiqueta}
              </button>
            ))}
          </div>

          {tags.length > 0 && (
            <DropdownMenu>
              <DropdownMenuTrigger
                className={cn(
                  "inline-flex items-center justify-center h-7 gap-1 px-2 text-xs rounded-md hover:bg-muted",
                  selectedTagIds.length > 0
                    ? "text-primary"
                    : "text-muted-foreground hover:text-foreground"
                )}
              >
                {t("tags")}
                {selectedTagIds.length > 0 && (
                  <span className="flex h-4 min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[10px] font-bold text-primary-foreground">
                    {selectedTagIds.length}
                  </span>
                )}
                <ChevronDown className="h-3 w-3" />
              </DropdownMenuTrigger>
              <DropdownMenuContent
                align="start"
                className="max-h-64 w-56 border-border bg-popover"
              >
                {tags.map((t) => (
                  <DropdownMenuCheckboxItem
                    key={t.id}
                    checked={selectedTagIds.includes(t.id)}
                    onCheckedChange={() => toggleTag(t.id)}
                    className="text-sm text-popover-foreground"
                  >
                    <span className="flex items-center gap-2">
                      <span
                        className="h-2 w-2 shrink-0 rounded-full"
                        style={{ backgroundColor: t.color }}
                      />
                      <span className="truncate">{t.name}</span>
                    </span>
                  </DropdownMenuCheckboxItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          )}

          {companies.length > 0 && (
            <DropdownMenu>
              <DropdownMenuTrigger
                className={cn(
                  "inline-flex max-w-40 items-center justify-center h-7 gap-1 px-2 text-xs rounded-md hover:bg-muted",
                  selectedCompany
                    ? "text-primary"
                    : "text-muted-foreground hover:text-foreground"
                )}
              >
                <span className="truncate">{selectedCompany ?? t("company")}</span>
                <ChevronDown className="h-3 w-3 shrink-0" />
              </DropdownMenuTrigger>
              <DropdownMenuContent
                align="start"
                className="max-h-64 w-56 border-border bg-popover"
              >
                <DropdownMenuItem
                  onClick={() => setSelectedCompany(null)}
                  className={cn(
                    "text-sm",
                    selectedCompany === null
                      ? "text-primary"
                      : "text-popover-foreground"
                  )}
                >
                  {t("allCompanies")}
                </DropdownMenuItem>
                {companies.map((co) => (
                  <DropdownMenuItem
                    key={co}
                    onClick={() => setSelectedCompany(co)}
                    className={cn(
                      "text-sm",
                      selectedCompany === co
                        ? "text-primary"
                        : "text-popover-foreground"
                    )}
                  >
                    <span className="truncate">{co}</span>
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          )}

          {onMarkAllRead && (
            <button
              type="button"
              onClick={onMarkAllRead}
              disabled={!hasUnreadConversations}
              className="inline-flex items-center justify-center h-7 gap-1 px-2 text-xs text-muted-foreground hover:text-foreground rounded-md hover:bg-muted disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-transparent"
            >
              Marcar todas como leídas
            </button>
          )}
        </div>

        {hasContactFilters && (
          <div className="flex flex-wrap items-center gap-1">
            {selectedTagIds.map((id) => {
              const tag = tagsById.get(id);
              return (
                <button
                  key={id}
                  onClick={() => toggleTag(id)}
                  className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-[11px] text-foreground hover:bg-muted/70"
                >
                  <span
                    className="h-1.5 w-1.5 shrink-0 rounded-full"
                    style={{ backgroundColor: tag?.color ?? "var(--muted-foreground)" }}
                  />
                  <span className="max-w-24 truncate">{tag?.name ?? t("tags")}</span>
                  <X className="h-3 w-3" />
                </button>
              );
            })}
            {selectedCompany && (
              <button
                onClick={() => setSelectedCompany(null)}
                className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-[11px] text-foreground hover:bg-muted/70"
              >
                <span className="max-w-24 truncate">{selectedCompany}</span>
                <X className="h-3 w-3" />
              </button>
            )}
            <button
              onClick={clearContactFilters}
              className="px-1 text-[11px] text-muted-foreground hover:text-foreground"
            >
              {t("clearAll")}
            </button>
          </div>
        )}
      </div>

      {selectedVisibleIds.size > 0 && (
        <div className="flex items-center justify-between border-b border-border px-3 py-2">
          <span className="text-sm text-muted-foreground">
            {etiquetaSeleccion(selectedVisibleIds.size)}
          </span>
          <div className="flex items-center gap-3">
            <button
              onClick={clearSelection}
              className="text-xs text-muted-foreground hover:text-foreground transition-colors"
            >
              Cancelar
            </button>
            <button
              onClick={handleQuitarSeleccionadas}
              className="text-xs font-medium text-primary hover:text-primary/80 transition-colors"
            >
              Quitar del inbox
            </button>
          </div>
        </div>
      )}

      {/* Conversation Items.
          `min-h-0` is load-bearing: a flex child defaults to
          min-height:auto, so without it this ScrollArea grows to fit
          every conversation instead of shrinking to the remaining
          space — the list then overflows and gets clipped by the
          parent's overflow-hidden with no scrollbar (issue #229). */}
      <ScrollArea className="min-h-0 flex-1">
        {loading ? (
          <div className="flex items-center justify-center py-12">
            <div className="h-5 w-5 animate-spin rounded-full border-2 border-primary border-t-transparent" />
          </div>
        ) : filtered.length === 0 ? (
          <div className="px-4 py-12 text-center">
            <p className="text-sm text-muted-foreground">{t("noConversations")}</p>
          </div>
        ) : (
          <div className="flex flex-col">
            {filtered.map((conv) => (
              <ConversationItem
                key={conv.id}
                conversation={conv}
                isActive={conv.id === activeConversationId}
                onSelect={handleSelect}
                onPin={handlePin}
                onUnpin={handleUnpin}
                onDelete={handleDelete}
                nombresPorAgente={nombresPorAgente}
                operationStatus={operationStatuses.get(conv.id) ?? null}
                t={t}
                isSelected={selectedVisibleIds.has(conv.id)}
                modoSeleccion={modoSeleccion}
                onToggleSelect={toggleSelect}
                onLongPress={handleLongPress}
              />
            ))}
            <button
              type="button"
              onClick={() => setShowAll((prev) => !prev)}
              className="text-muted-foreground hover:text-foreground mx-2 my-3 rounded-lg border border-dashed border-border px-3 py-2 text-xs"
            >
              {showAll ? t("showRecentOnly") : t("showAll")}
            </button>
          </div>
        )}
      </ScrollArea>
    </div>
  );
}

interface ConversationItemProps {
  conversation: Conversation;
  isActive: boolean;
  onSelect: (conversation: Conversation) => void;
  onPin: (id: string) => void;
  onUnpin: (id: string) => void;
  onDelete: (id: string, name: string) => void;
  /** userId -> nombre. Cargado una vez por la lista. */
  nombresPorAgente?: ReadonlyMap<string, string>;
  /** Estado efectivo de su operación abierta más relevante, o null. */
  operationStatus?: EffectiveStatus | null;
  t: ReturnType<typeof useTranslations>;
  isSelected: boolean;
  /** Modo selección activo para toda la lista, no sólo esta fila. */
  modoSeleccion: boolean;
  onToggleSelect: (id: string) => void;
  /** Pulsación larga (táctil): entra en modo selección sin necesitar hover. */
  onLongPress: (id: string) => void;
}

function ConversationItem({
  conversation,
  isActive,
  onSelect,
  onPin,
  onUnpin,
  onDelete,
  nombresPorAgente,
  operationStatus = null,
  t,
  isSelected,
  modoSeleccion,
  onToggleSelect,
  onLongPress,
}: ConversationItemProps) {
  const tOps = useTranslations("Inbox.operationsPanel.status");
  // El nombre sólo existe cuando hay alguien ASIGNADO. Si la propiedad viene de
  // «una persona respondió a mano», no hay a quién nombrar: el CRM no guarda
  // quién escribió en la conversación, sólo que fue una persona.
  const { agentId } = resolveConversationOwnership(conversation);
  const nombreAgente = agentId ? (nombresPorAgente?.get(agentId) ?? null) : null;
  const contact = conversation.contact;
  const displayName = contact?.name || contact?.phone || t("unknown");

  const handleClick = useCallback(() => {
    onSelect(conversation);
  }, [onSelect, conversation]);

  // Fired on hover AND focus — keyboard users arrow through this list
  // and never trigger mouseenter (panel-26). The operations panel's
  // single round trip can't get faster, only earlier; this starts it
  // the moment a row becomes the likely next click, so it's often
  // already in hand by the time onSelect fires above.
  const handlePrefetch = useCallback(() => {
    prefetchConversationOperations(conversation.id);
  }, [conversation.id]);

  const timeAgo = conversation.last_message_at
    ? formatDistanceToNow(new Date(conversation.last_message_at), {
        addSuffix: false,
      })
    : "";

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={handleClick}
      onMouseEnter={handlePrefetch}
      onFocus={handlePrefetch}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          handleClick();
        }
      }}
      onContextMenu={(e) => {
        // En táctil la pulsación larga dispara `contextmenu`. Es el mismo
        // patrón que ya usa MessageActions para su barra: no se inventa una
        // interacción nueva sólo para el Inbox.
        e.preventDefault();
        if (!modoSeleccion) onLongPress(conversation.id);
      }}
      className={cn(
        "group flex w-full cursor-pointer items-start gap-3 border-b border-border/60 px-3 py-3 text-left transition-colors hover:bg-muted/50",
        isActive && "bg-primary-soft shadow-[inset_2px_0_0_var(--primary)]"
      )}
    >
      {/* Avatar, que en hover y en modo selección se convierte en casilla.
          Los dos ocupan la MISMA caja de 10×10 y se superponen: así el nombre
          y el resto de la fila no se mueven ni un píxel al cambiar. */}
      <div className="relative h-10 w-10 shrink-0">
        <div
          aria-hidden={modoSeleccion || isSelected}
          className={cn(
            "transition-opacity",
            modoSeleccion || isSelected
              ? "opacity-0"
              : "group-hover:opacity-0 group-focus-within:opacity-0"
          )}
        >
          <ContactAvatar
            seed={contact?.id || conversation.id || displayName}
            name={displayName}
            gender={contact?.avatar_gender}
            seq={contact?.avatar_seq}
            imageUrl={contact?.avatar_url}
            className="h-10 w-10 bg-primary-soft text-sm font-bold text-primary"
          />
        </div>
        <div
          className={cn(
            "absolute inset-0 flex items-center justify-center transition-opacity",
            modoSeleccion || isSelected
              ? "opacity-100"
              : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
          )}
        >
          {/* El stopPropagation va en un envoltorio y no en la casilla: el
              primitivo no reenvía onClick a su raíz, así que el clic subía a
              la fila y abría la conversación además de marcarla. */}
          {/* `inline-flex` es obligatorio: el primitivo se pinta como <span>
              en línea, y en un elemento en línea el `size-4` no aplica. Sin
              esto la casilla salía de 2 px de ancho y no se podía pulsar. */}
          <span
            className="inline-flex"
            onClick={(e) => e.stopPropagation()}
            onKeyDown={(e) => e.stopPropagation()}
          >
            <Checkbox
              checked={isSelected}
              aria-label={`Seleccionar conversación con ${displayName}`}
              onCheckedChange={() => onToggleSelect(conversation.id)}
            />
          </span>
        </div>
      </div>

      {/* Content */}
      <div className="min-w-0 flex-1">
        <div className="flex items-center justify-between gap-2">
          <span className="flex min-w-0 items-center gap-1.5">
            <span className="truncate text-sm font-semibold text-foreground">
              {displayName}
            </span>
          </span>
          <span className="flex shrink-0 items-center gap-1">
            <span className="shrink-0 text-[10px] text-muted-foreground">
              {timeAgo}
            </span>
            <button
              type="button"
              aria-label={
                conversation.pinned_at ? "Desfijar conversación" : "Fijar conversación"
              }
              aria-pressed={!!conversation.pinned_at}
              title={conversation.pinned_at ? "Desfijar" : "Fijar"}
              disabled={modoSeleccion}
              onClick={(e) => {
                e.stopPropagation();
                if (conversation.pinned_at) {
                  onUnpin(conversation.id);
                } else {
                  onPin(conversation.id);
                }
              }}
              className={cn(
                "rounded p-0.5 transition-all",
                conversation.pinned_at
                  ? "text-primary opacity-100"
                  : "text-muted-foreground opacity-0 group-hover:opacity-100 hover:text-foreground",
                // En modo selección manda la casilla: ningún pin responde,
                // para que un clic despistado no cambie nada. Pero el de una
                // fila FIJADA se queda a la vista: si se atenuara también, se
                // perdería de un plumazo saber cuáles estaban fijadas.
                modoSeleccion && "pointer-events-none",
                modoSeleccion && !conversation.pinned_at && "opacity-30"
              )}
            >
              <Pin
                className={cn(
                  "h-3.5 w-3.5",
                  conversation.pinned_at && "fill-current"
                )}
              />
            </button>
          </span>
        </div>
        <div className="mt-0.5 flex items-center justify-between gap-2">
          <p className="flex min-w-0 items-center gap-1.5 truncate text-xs text-muted-foreground">
            {/* Delante del mensaje: sitio fijo, no lo empuja la longitud del
                nombre y no choca con la hora. */}
            <OwnershipIcon conversation={conversation} agentName={nombreAgente} />
            <span className="truncate">
              {conversation.last_message_text || t("noMessagesYet")}
            </span>
          </p>
          <div className="flex shrink-0 items-center gap-1.5">
            {conversation.unread_count > 0 && (
              <span className="flex h-4 min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[10px] font-bold text-primary-foreground">
                {conversation.unread_count}
              </span>
            )}
            {conversation.status !== "open" && (
              <span
                className={cn(
                  "h-2 w-2 rounded-full",
                  STATUS_COLORS[conversation.status]
                )}
                title={conversation.status}
              />
            )}
          </div>
        </div>
        {operationStatus && (
          <div className="mt-1 flex">
            <span
              data-testid="operation-status-chip"
              data-tone={statusTone(operationStatus)}
              className={cn(
                "max-w-full truncate rounded-full px-1.5 text-[10px] font-medium leading-4",
                statusPillClass[statusTone(operationStatus)],
              )}
            >
              {tOps(operationStatus)}
            </span>
          </div>
        )}
      </div>
    </div>
  );
}
