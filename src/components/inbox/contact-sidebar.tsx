"use client";

import { useState, useEffect, useCallback } from "react";
import type { CSSProperties } from "react";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { cn } from "@/lib/utils";
import type { Contact, Conversation, Deal, ContactNote, Tag } from "@/types";
import {
  Phone,
  Mail,
  Copy,
  Check,
  User,
  Tag as TagIcon,
  DollarSign,
  StickyNote,
  Plus,
  Bot,
  Pause,
  Play,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { formatCurrency } from "@/lib/currency";
import { StageBadge } from "@/components/pipelines/stage-badge";
import { format } from "date-fns";
import { toast } from "sonner";
import { useTranslations } from "next-intl";

interface ContactSidebarProps {
  contact: Contact | null;
  /** Hilo abierto. Hace falta para pausar el bot, que es por conversacion. */
  conversation?: Conversation | null;
  /** Permite reutilizar el mismo panel dentro del drawer móvil. */
  className?: string;
}

/**
 * Tope de deals que se traen para el panel del chat.
 *
 * La consulta no tenia ninguno: pedia todas las remesas que ese contacto
 * hubiera hecho jamas. Un cliente veterano de staging ya acumula 127, y ese
 * numero solo sube. 50 cubre de sobra lo que un operador mira, y el total
 * real se sigue sabiendo por el `count` de la misma llamada.
 */
const DEALS_MAXIMO = 50;

/** Cuantos se ven sin desplegar. El resto queda tras "ver todas". */
const DEALS_VISIBLES = 4;

export function ContactSidebar({ contact, conversation, className }: ContactSidebarProps) {
  const tSidebar = useTranslations("Inbox.sidebar");
  const tThread = useTranslations("Inbox.messageThread");

  const { accountId } = useAuth();
  const [copied, setCopied] = useState(false);
  const [deals, setDeals] = useState<Deal[]>([]);
  /** Cuantos tiene en total, aunque solo se hayan traido DEALS_MAXIMO. */
  const [dealsTotal, setDealsTotal] = useState(0);
  /** Abiertos de verdad, no solo entre los descargados. */
  const [dealsAbiertosTotal, setDealsAbiertosTotal] = useState(0);
  const [verTodosLosDeals, setVerTodosLosDeals] = useState(false);
  const [notes, setNotes] = useState<ContactNote[]>([]);
  const [tags, setTags] = useState<(Tag & { contact_tag_id: string })[]>([]);
  const [newNote, setNewNote] = useState("");
  const [addingNote, setAddingNote] = useState(false);
  // Pausa del bot en ESTE hilo (`conversations.ai_autoreply_disabled`).
  // Espejo local optimista para que el boton responda al instante; se
  // re-siembra al cambiar de conversacion o cuando llega el valor del
  // servidor por realtime.
  const [botPaused, setBotPaused] = useState(false);
  const [botBusy, setBotBusy] = useState(false);
  useEffect(() => {
    setBotPaused(conversation?.ai_autoreply_disabled ?? false);
  }, [conversation?.id, conversation?.ai_autoreply_disabled]);

  const toggleBot = useCallback(async () => {
    if (!conversation) return;
    const next = !botPaused;
    setBotBusy(true);
    try {
      // Se reusa el endpoint que ya existia. `assign_to_me` se OMITE a
      // proposito: pausar no debe apropiarse del chat. Al reanudar, el
      // endpoint libera cualquier asignacion, que hace falta porque el
      // Cerebro tambien se calla con el chat asignado.
      const res = await fetch(`/api/ai/autoreply/${conversation.id}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ paused: next }),
      });
      if (!res.ok) {
        toast.error(tSidebar("botError"));
        return;
      }
      setBotPaused(next);
      toast.success(next ? tSidebar("botPaused") : tSidebar("botResumed"));
    } catch {
      toast.error(tSidebar("botError"));
    } finally {
      setBotBusy(false);
    }
  }, [conversation, botPaused, tSidebar]);

  const fetchContactData = useCallback(async () => {
    if (!contact) return;

    const supabase = createClient();

    // Fetch deals, notes, and tags in parallel
    const [dealsRes, notesRes, tagsRes] = await Promise.all([
      // Con tope: la lista crecia con la antiguedad del cliente y se traia
      // cada remesa que hubiera hecho nunca. `count: 'exact'` devuelve el
      // total real en la misma llamada, para poder decir cuantas hay sin
      // descargarlas todas.
      supabase
        .from("deals")
        .select("*, stage:pipeline_stages(*)", { count: "exact" })
        .eq("contact_id", contact.id)
        .order("created_at", { ascending: false })
        .limit(DEALS_MAXIMO),
      supabase
        .from("contact_notes")
        .select("*")
        .eq("contact_id", contact.id)
        .order("created_at", { ascending: false }),
      supabase
        .from("contact_tags")
        .select("id, tag_id, tags(*)")
        .eq("contact_id", contact.id),
    ]);

    if (dealsRes.data) setDeals(dealsRes.data);
    setDealsTotal(dealsRes.count ?? dealsRes.data?.length ?? 0);
    // El numero de abiertos se pide aparte y con `head`, sin traer filas.
    // Contarlos sobre los DEALS_MAXIMO descargados daria una cifra menor que
    // la real —"27 abiertas" cuando hay 67— y un recuento que se queda corto
    // en un panel de dinero es peor que no ensenar ninguno.
    const abiertosRes = await supabase
      .from("deals")
      .select("id", { count: "exact", head: true })
      .eq("contact_id", contact.id)
      .eq("status", "open");
    setDealsAbiertosTotal(abiertosRes.count ?? 0);
    if (notesRes.data) setNotes(notesRes.data);
    if (tagsRes.data) {
      const mapped = tagsRes.data
        .filter((ct: Record<string, unknown>) => ct.tags)
        .map((ct: Record<string, unknown>) => ({
          ...(ct.tags as Tag),
          contact_tag_id: ct.id as string,
        }));
      setTags(mapped);
    }
  }, [contact]);

  // Load on contact change. setContactData/setTags run inside async
  // Supabase callbacks, not synchronously in the effect body.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    fetchContactData();
  }, [fetchContactData]);

  const handleCopyPhone = useCallback(async () => {
    if (!contact?.phone) return;
    await navigator.clipboard.writeText(contact.phone);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
    // Dep is the whole `contact` object (not `contact?.phone`) so the
    // React Compiler's inference agrees with the manual dep list —
    // fixes the `preserve-manual-memoization` lint error.
  }, [contact]);

  const handleAddNote = useCallback(async () => {
    if (!contact || !newNote.trim()) return;
    if (!accountId) return;
    setAddingNote(true);

    const supabase = createClient();
    const {
      data: { session },
    } = await supabase.auth.getSession();
    const user = session?.user;

    const { data, error } = await supabase
      .from("contact_notes")
      .insert({
        contact_id: contact.id,
        account_id: accountId,
        user_id: user?.id,
        note_text: newNote.trim(),
      })
      .select()
      .single();

    if (!error && data) {
      setNotes((prev) => [data, ...prev]);
      setNewNote("");
    }
    setAddingNote(false);
  }, [contact, newNote, accountId]);

  if (!contact) {
    return (
      <div className={cn("flex h-full w-70 items-center justify-center border-l border-border bg-card", className)}>
        <p className="text-sm text-muted-foreground">{tThread("selectConversation")}</p>
      </div>
    );
  }

  const displayName = contact.name || contact.phone;
  const initials = displayName.charAt(0).toUpperCase();

  // Lo abierto primero: es lo unico que puede pedir una accion ahora mismo.
  // Lo entregado o perdido es historia y se va detras. Dentro de cada grupo
  // se conserva el orden de la consulta (mas reciente primero).
  const dealsAbiertos = deals.filter((d) => d.status === "open");
  const dealsCerrados = deals.filter((d) => d.status !== "open");
  const dealsOrdenados = [...dealsAbiertos, ...dealsCerrados];
  const dealsVisibles = verTodosLosDeals
    ? dealsOrdenados
    : dealsOrdenados.slice(0, DEALS_VISIBLES);
  const dealsOcultos = dealsOrdenados.length - DEALS_VISIBLES;

  return (
    <div className={cn("flex h-full w-70 flex-col border-l border-border bg-card", className)}>
      {/* `min-h-0` es imprescindible, no decorativo: sin el, este hijo flex
          conserva `min-height: auto` y se niega a encoger por debajo de su
          contenido. Con un cliente veterano (127 deals = 11.387px) el visor
          crecia hasta el tamano de la lista en vez de recortarla, y el area
          dejaba de tener scroll: el boton de pausar el bot quedaba a 11.000px
          del borde, inalcanzable incluso desplazando. Mismo fallo que el
          `min-w-0` del eje horizontal en inbox/page.tsx (#165). */}
      <ScrollArea className="min-h-0 flex-1">
        <div className="p-4">
          {/* Contact Info */}
          <div className="flex flex-col items-center text-center">
            <div className="flex h-16 w-16 items-center justify-center rounded-full bg-muted text-lg font-semibold text-foreground">
              {contact.avatar_url ? (
                <img
                  src={contact.avatar_url}
                  alt={displayName}
                  className="h-16 w-16 rounded-full object-cover"
                />
              ) : (
                initials
              )}
            </div>
            <h3 className="mt-3 text-sm font-semibold text-foreground">
              {displayName}
            </h3>
            {contact.company && (
              <p className="text-xs text-muted-foreground">{contact.company}</p>
            )}
          </div>

          {/* Bot — PRIMERO a proposito. Estaba al final, detras de deals y
              notas, dos listas que crecen sin tope: con un cliente veterano
              el boton quedaba a 11.000px del borde. Un control que corta la
              respuesta automatica no puede depender de cuantas remesas lleve
              hechas esa persona.

              Existe aparte del banner Existe aparte del banner
              de IA de WaCRM (`AiThreadBanner`) a proposito: aquel solo se
              dibuja si esta encendida la IA PROPIA de WaCRM, y aqui el bot
              es el Cerebro en n8n, asi que nunca aparecia. */}
          {conversation && (
            <>
              <div className="my-4 border-t border-border" />
              <div>
                <div className="flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                  <Bot className="h-3 w-3" />
                  {tSidebar("bot")}
                </div>
                <div className="mt-2">
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={toggleBot}
                    disabled={botBusy}
                    className="w-full justify-start border-border bg-transparent text-xs text-foreground hover:bg-muted"
                  >
                    {botPaused ? (
                      <Play className="mr-2 h-3 w-3 text-primary" />
                    ) : (
                      <Pause className="mr-2 h-3 w-3 text-muted-foreground" />
                    )}
                    {botPaused ? tSidebar("resumeBot") : tSidebar("pauseBot")}
                  </Button>
                  <p className="mt-1.5 px-1 text-[10px] leading-snug text-muted-foreground">
                    {botPaused ? tSidebar("botPausedHint") : tSidebar("botActiveHint")}
                  </p>
                </div>
              </div>
            </>
          )}

          {/* Phone */}
          <div className="mt-4 space-y-2">
            <button
              onClick={handleCopyPhone}
              className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted-foreground transition-colors hover:bg-muted"
            >
              <Phone className="h-4 w-4 text-muted-foreground" />
              <span className="flex-1 text-left">{contact.phone}</span>
              {copied ? (
                <Check className="h-3 w-3 text-primary" />
              ) : (
                <Copy className="h-3 w-3 text-muted-foreground" />
              )}
            </button>

            {contact.email && (
              <div className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted-foreground">
                <Mail className="h-4 w-4 text-muted-foreground" />
                <span className="truncate">{contact.email}</span>
              </div>
            )}
          </div>

          {/* Divider */}
          <div className="my-4 border-t border-border" />

          {/* Tags */}
          <div>
            <div className="flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
              <TagIcon className="h-3 w-3" />
              {tSidebar("tags")}
            </div>
            <div className="mt-2 flex flex-wrap gap-1">
              {tags.length === 0 ? (
                <p className="px-1 text-xs text-muted-foreground">{tSidebar("noTags")}</p>
              ) : (
                tags.map((tag) => (
                  <span
                    key={tag.contact_tag_id}
                    className="pastilla-color rounded-full px-2 py-0.5 text-[10px] font-medium"
                    style={{ "--tono": tag.color } as CSSProperties}
                  >
                    {tag.name}
                  </span>
                ))
              )}
            </div>
          </div>

          {/* Divider */}
          <div className="my-4 border-t border-border" />

          {/* Active Deals */}
          <div>
            <div className="flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
              <DollarSign className="h-3 w-3" />
              {tSidebar("deals")}
              {dealsTotal > 0 && (
                <span className="ml-auto tracking-normal normal-case">
                  {tSidebar("dealsSummary", {
                    open: dealsAbiertosTotal,
                    total: dealsTotal,
                  })}
                </span>
              )}
            </div>
            <div className="mt-2 space-y-2">
              {deals.length === 0 ? (
                <p className="px-1 text-xs text-muted-foreground">{tSidebar("noDeals")}</p>
              ) : (
                <>
                  {dealsVisibles.map((deal) => {
                    return (
                      <div key={deal.id} className="rounded-lg bg-muted px-3 py-2">
                        <p className="truncate text-sm font-medium text-foreground">
                          {deal.title}
                        </p>
                        <div className="mt-1 flex items-center justify-between gap-2 text-xs text-muted-foreground">
                          {/* Antes: `{deal.currency ?? "$"}{deal.value.toLocaleString()}`,
                              que pegaba codigo y numero sin espacio — "GYD25,000". */}
                          <span className="tabular-nums">
                            {formatCurrency(deal.value, deal.currency)}
                          </span>
                          {deal.stage && (
                            <StageBadge
                              name={deal.stage.name}
                              color={deal.stage.color}
                              className="px-1.5 text-[10px]"
                            />
                          )}
                        </div>
                      </div>
                    );
                  })}
                  {dealsOcultos > 0 && (
                    <button
                      type="button"
                      onClick={() => setVerTodosLosDeals((v) => !v)}
                      className="w-full cursor-pointer rounded-lg px-3 py-1.5 text-xs font-medium text-primary transition-colors hover:bg-muted"
                    >
                      {verTodosLosDeals
                        ? tSidebar("dealsShowLess")
                        : tSidebar("dealsShowAll", { count: dealsOcultos })}
                    </button>
                  )}
                  {verTodosLosDeals && dealsTotal > deals.length && (
                    // Desplegar no ensena "todos": ensena los descargados. Sin
                    // esta linea, un cliente con 127 remesas parece tener 50.
                    <p className="px-3 text-[10px] text-muted-foreground">
                      {tSidebar("dealsTruncated", {
                        shown: deals.length,
                        total: dealsTotal,
                      })}
                    </p>
                  )}
                </>
              )}
            </div>
          </div>

          {/* Divider */}
          <div className="my-4 border-t border-border" />

          {/* Notes */}
          <div>
            <div className="flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
              <StickyNote className="h-3 w-3" />
              {tSidebar("notes")}
            </div>
            <div className="mt-2">
              <div className="flex gap-2">
                <textarea
                  value={newNote}
                  onChange={(e) => setNewNote(e.target.value)}
                  placeholder={tSidebar("addNotePlaceholder")}
                  rows={2}
                  className="flex-1 resize-none rounded-lg border border-border bg-muted px-3 py-2 text-xs text-foreground placeholder-muted-foreground outline-none focus:border-primary/50"
                />
                <Button
                  size="sm"
                  className="h-auto bg-primary px-2 hover:bg-primary/90"
                  onClick={handleAddNote}
                  disabled={!newNote.trim() || addingNote}
                >
                  <Plus className="h-3 w-3" />
                </Button>
              </div>

              <div className="mt-2 space-y-2">
                {notes.map((note) => (
                  <div
                    key={note.id}
                    className="rounded-lg bg-muted px-3 py-2"
                  >
                    <p className="whitespace-pre-wrap text-xs text-muted-foreground">
                      {note.note_text}
                    </p>
                    <p className="mt-1 text-[10px] text-muted-foreground">
                      {format(new Date(note.created_at), "MMM d, yyyy HH:mm")}
                    </p>
                  </div>
                ))}
              </div>
            </div>
          </div>

        </div>
      </ScrollArea>
    </div>
  );
}
