"use client";

import { useState, useEffect, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { cn } from "@/lib/utils";
import type { Contact, Conversation, ContactNote, Tag } from "@/types";
import {
  Phone,
  Mail,
  Copy,
  Check,
  User,
  Tag as TagIcon,
  StickyNote,
  Plus,
  Bot,
} from "lucide-react";
import { ContactAvatar } from "@/components/contacts/contact-avatar";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { ScrollArea } from "@/components/ui/scroll-area";
import { format } from "date-fns";
import { toast } from "sonner";
import { useTranslations } from "next-intl";
import { OperationsPanelContainer } from "@/components/inbox/operations/operations-panel-container";

interface ContactSidebarProps {
  contact: Contact | null;
  /** Hilo abierto. Hace falta para pausar el bot, que es por conversacion. */
  conversation?: Conversation | null;
  /** Permite reutilizar el mismo panel dentro del drawer móvil. */
  className?: string;
}

export function ContactSidebar({ contact, conversation, className }: ContactSidebarProps) {
  const tSidebar = useTranslations("Inbox.sidebar");
  const tThread = useTranslations("Inbox.messageThread");

  const { accountId, profile } = useAuth();
  // Design decision 8 (port-chat-operations-calculator): the read-only
  // remesa operations panel (Slice 5) is visible ONLY behind this beta
  // flag; the API route enforces the same gate server-side (404 when
  // absent), so this is a UI convenience, not the security boundary.
  const operationsPanelEnabled = profile?.beta_features?.includes("operations_panel") ?? false;
  const [copied, setCopied] = useState(false);
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

    // Fetch notes and tags in parallel
    const [notesRes, tagsRes] = await Promise.all([
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

  return (
    <div className={cn("flex h-full w-70 flex-col border-l border-border bg-card", className)}>
      <ScrollArea className="min-h-0 flex-1">
        <div className="p-4">
          {/* Contact Info */}
          <div className="flex flex-col items-center text-center">
            <ContactAvatar
              seed={contact.id || conversation?.id || displayName}
              name={displayName}
              gender={contact.avatar_gender}
              seq={contact.avatar_seq}
              imageUrl={contact.avatar_url}
              className="h-16 w-16 bg-primary-soft text-lg font-bold text-primary"
            />
            <h3 className="mt-3 font-heading text-base font-bold text-foreground">
              {displayName}
            </h3>
            {contact.company && (
              <p className="text-xs text-muted-foreground">{contact.company}</p>
            )}
          </div>

          {/* Phone */}
          <div className="mt-4 space-y-2">
            <button
              onClick={handleCopyPhone}
              className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted-foreground transition-colors hover:bg-muted"
            >
              <Phone className="h-4 w-4 text-muted-foreground" />
              <span className="flex-1 text-left font-mono tabular-nums">{contact.phone}</span>
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

          {/* Bot — pausar / reanudar en este hilo. Existe aparte del banner
              de IA de WaCRM (`AiThreadBanner`) a proposito: aquel solo se
              dibuja si esta encendida la IA PROPIA de WaCRM, y aqui el bot
              es el Cerebro en n8n, asi que nunca aparecia. */}
          {conversation && (
            <>
              <div className="my-4 border-t border-border" />
              <div>
                <div className="flex items-center justify-between gap-2 px-1">
                  <div className="flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    <Bot className="h-3 w-3" />
                    {tSidebar("bot")}
                  </div>
                  <Switch
                    checked={botPaused}
                    onCheckedChange={toggleBot}
                    disabled={botBusy}
                    aria-label={botPaused ? tSidebar("resumeBot") : tSidebar("pauseBot")}
                  />
                </div>
                <p className="mt-1.5 px-1 text-[10px] leading-snug text-muted-foreground">
                  {botPaused ? tSidebar("botPausedHint") : tSidebar("botActiveHint")}
                </p>
              </div>
            </>
          )}
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
                    className="rounded-full px-2 py-0.5 text-[10px] font-medium"
                    style={{
                      backgroundColor: `${tag.color}20`,
                      color: tag.color,
                    }}
                  >
                    {tag.name}
                  </span>
                ))
              )}
            </div>
          </div>

          {/* Remittance operations panel (Slice 5, read-only) — beta flag
              gated (design decision 8). `conversation` must be present:
              the panel reads per-conversation, not per-contact. */}
          {operationsPanelEnabled && conversation && (
            <>
              <div className="my-4 border-t border-border" />
              <OperationsPanelContainer conversationId={conversation.id} />
            </>
          )}

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
