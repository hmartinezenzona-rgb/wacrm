"use client";

import { useState, useEffect, useCallback, useMemo, useRef } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  CONVERSATION_SELECT,
  matchesContactFilters,
  normalizeConversations,
} from "@/lib/inbox/conversations";
import { prefetchConversationOperations } from "@/lib/remittance-operations/panel-prefetch";
import { cn } from "@/lib/utils";
import type { Conversation, ConversationStatus, Tag } from "@/types";
import { Search, ChevronDown, X, Pin, Check } from "lucide-react";
import { OwnershipIcon } from "./ownership-icon";
import {
  resolveConversationOwnership,
  type ConversationOwnership,
} from "@/lib/inbox/conversation-ownership";
import { toast } from "sonner";
import { formatDistanceToNow } from "date-fns";
import { useTranslations } from "next-intl";
import { Input } from "@/components/ui/input";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { ScrollArea } from "@/components/ui/scroll-area";

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

export function ConversationList({
  activeConversationId,
  onSelect,
  conversations,
  onConversationsLoaded,
  resyncToken = 0,
}: ConversationListProps) {
  const t = useTranslations("Inbox.conversationList");
  
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
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
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

  const fetchConversations = useCallback(async (): Promise<Conversation[] | null> => {
    const supabase = createClient();
    const { data, error } = await supabase
      .from("conversations")
      .select(CONVERSATION_SELECT)
      .is("deleted_at", null)
      .order("pinned_at", { ascending: false, nullsFirst: false })
      .order("last_message_at", { ascending: false });

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
    return normalizeConversations(data ?? []);
  }, []);

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
    [applyConversationUpdate],
  );

  const toggleSelect = useCallback((id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const handleBatchArchive = useCallback(() => {
    const count = selectedIds.size;
    if (count === 0) return;
    if (!window.confirm(`¿Ocultar ${count} chats?`)) return;
    void (async () => {
      const names: string[] = [];
      for (const id of selectedIds) {
        const conv = conversations.find((c) => c.id === id);
        if (conv) names.push(conv.contact?.name || conv.contact?.phone || "");
        await applyConversationUpdate(id, {
          deleted_at: new Date().toISOString(),
        });
      }
      setSelectedIds(new Set());
      toast("Chats ocultos", {
        description: `${count} chats se ocultaron de la lista.${
          names.length > 0 ? ` (${names.join(", ")})` : ""
        }`,
      });
    })();
  }, [selectedIds, applyConversationUpdate, conversations]);

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
    <div className="flex h-full w-full flex-col border-r border-border bg-card lg:w-80">
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

      {selectedIds.size > 0 && (
        <div className="flex items-center justify-between border-b border-border px-3 py-2">
          <span className="text-sm text-muted-foreground">
            {selectedIds.size} seleccionad{selectedIds.size === 1 ? "o" : "os"}
          </span>
          <div className="flex items-center gap-3">
            <button
              onClick={() => setSelectedIds(new Set())}
              className="text-xs text-muted-foreground hover:text-foreground transition-colors"
            >
              Limpiar
            </button>
            <button
              onClick={handleBatchArchive}
              className="text-xs font-medium text-primary hover:text-primary/80 transition-colors"
            >
              Archivar {selectedIds.size}
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
                t={t}
                isSelected={selectedIds.has(conv.id)}
                onToggleSelect={toggleSelect}
              />
            ))}
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
  t: ReturnType<typeof useTranslations>;
  isSelected: boolean;
  onToggleSelect: (id: string) => void;
}

function ConversationItem({
  conversation,
  isActive,
  onSelect,
  onPin,
  onUnpin,
  onDelete,
  nombresPorAgente,
  t,
  isSelected,
  onToggleSelect,
}: ConversationItemProps) {
  // El nombre sólo existe cuando hay alguien ASIGNADO. Si la propiedad viene de
  // «una persona respondió a mano», no hay a quién nombrar: el CRM no guarda
  // quién escribió en la conversación, sólo que fue una persona.
  const { agentId } = resolveConversationOwnership(conversation);
  const nombreAgente = agentId ? (nombresPorAgente?.get(agentId) ?? null) : null;
  const contact = conversation.contact;
  const displayName = contact?.name || contact?.phone || t("unknown");
  const initials = displayName.charAt(0).toUpperCase();

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
      className={cn(
        "group flex w-full cursor-pointer items-start gap-3 px-3 py-3 text-left transition-colors hover:bg-muted/50",
        isActive && "border-l-2 border-primary bg-muted/70"
      )}
    >
      {/* Avatar with checkbox overlay on hover */}
      <div className="relative flex h-10 w-10 shrink-0 items-center justify-center">
        <div
          className={cn(
            "flex h-full w-full items-center justify-center rounded-full bg-muted text-sm font-medium text-foreground transition-all",
            isSelected && "opacity-40",
            !isSelected && "group-hover:opacity-0"
          )}
        >
          {contact?.avatar_url ? (
            <img
              src={contact.avatar_url}
              alt={displayName}
              className="h-10 w-10 rounded-full object-cover"
            />
          ) : (
            initials
          )}
        </div>
        <button
          onClick={(e) => {
            e.stopPropagation();
            onToggleSelect(conversation.id);
          }}
          className={cn(
            "absolute inset-0 flex items-center justify-center rounded-full transition-all",
            "opacity-0 group-hover:opacity-100",
            isSelected && "opacity-100"
          )}
        >
          <div
            className="flex h-full w-full items-center justify-center rounded-full bg-muted transition-colors"
          >
            <div
              className={cn(
                "flex h-5 w-5 items-center justify-center rounded-sm border-2 transition-colors",
                isSelected
                  ? "border-primary bg-primary"
                  : "border-muted-foreground bg-background"
              )}
            >
              {isSelected && <Check className="h-3 w-3 text-primary-foreground" />}
            </div>
          </div>
        </button>
      </div>

      {/* Content */}
      <div className="min-w-0 flex-1">
        <div className="flex items-center justify-between gap-2">
          <span className="flex min-w-0 items-center gap-1.5">
            <span className="truncate text-sm font-medium text-foreground">
              {displayName}
            </span>
          </span>
          <span className="flex shrink-0 items-center gap-1">
            <span className="shrink-0 text-[10px] text-muted-foreground">
              {timeAgo}
            </span>
            <button
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
                  : "text-muted-foreground opacity-0 group-hover:opacity-100 hover:text-foreground"
              )}
              title={conversation.pinned_at ? "Desfijar" : "Fijar"}
            >
              <Pin className={cn("h-3 w-3", conversation.pinned_at && "fill-primary")} />
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
      </div>
    </div>
  );
}
