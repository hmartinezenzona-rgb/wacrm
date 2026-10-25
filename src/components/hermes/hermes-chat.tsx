'use client';

// ============================================================
// HermesChat — the admin's chat with Hermes inside the panel.
//
// Sends the whole short conversation to /api/hermes/chat (which proxies the
// Hermes API server); Hermes answers with its read-only CRM tools.
// ============================================================

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import {
  AlertTriangle,
  ArrowRight,
  BarChart3,
  ClipboardCheck,
  Loader2,
  MessageSquare,
  Plus,
  Send,
  Sparkles,
} from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/hooks/use-auth';

interface Turn {
  role: 'user' | 'assistant';
  content: string;
}

// The conversation survives leaving the page and reloading the tab, so it is
// only lost when the admin presses "Nueva conversación" or closes the tab.
const STORAGE_KEY = 'wacrm.hermes.chat.v1';

function isTurn(value: unknown): value is Turn {
  if (!value || typeof value !== 'object') return false;
  const turn = value as Record<string, unknown>;
  return (turn.role === 'user' || turn.role === 'assistant') && typeof turn.content === 'string';
}

export function HermesChat() {
  const t = useTranslations('Hermes');
  const [turns, setTurns] = useState<Turn[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement | null>(null);
  const scrollerRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const { profile } = useAuth();
  // La maqueta saluda por el nombre de pila; sin perfil, saludo a secas.
  const firstName = profile?.full_name?.trim().split(/\s+/)[0] ?? '';

  // Read after mount: the server render has no sessionStorage.
  useEffect(() => {
    try {
      const raw = sessionStorage.getItem(STORAGE_KEY);
      if (raw) {
        const saved = JSON.parse(raw) as unknown;
        if (Array.isArray(saved)) setTurns(saved.filter(isTurn));
      }
    } catch {
      // Unreadable or blocked storage: start clean.
    }
    setLoaded(true);
  }, []);

  useEffect(() => {
    if (!loaded) return;
    try {
      if (turns.length === 0) {
        sessionStorage.removeItem(STORAGE_KEY);
      } else {
        sessionStorage.setItem(STORAGE_KEY, JSON.stringify(turns));
      }
    } catch {
      // Storage full or blocked: the chat keeps working in memory.
    }
  }, [turns, loaded]);

  useEffect(() => {
    // The greeting and the idea cards fill more than one screen on a phone:
    // scrolling to the bottom on mount would hide both. Only a conversation
    // follows its last turn; the empty state always starts at the top.
    if (turns.length === 0 && !busy) {
      scrollerRef.current?.scrollTo({ top: 0 });
      return;
    }
    bottomRef.current?.scrollIntoView({ block: 'end' });
  }, [turns, busy]);

  /** Una tarjeta de idea escribe su pregunta en el compositor y la enfoca. */
  function pickIdea(prompt: string) {
    setInput(prompt);
    setError(null);
    requestAnimationFrame(() => {
      const el = textareaRef.current;
      el?.focus();
      el?.setSelectionRange(prompt.length, prompt.length);
    });
  }

  function startNewChat() {
    setTurns([]);
    setInput('');
    setError(null);
  }

  async function send() {
    const text = input.trim();
    if (!text || busy) return;
    const next: Turn[] = [...turns, { role: 'user', content: text }];
    setTurns(next);
    setInput('');
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/hermes/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ messages: next.slice(-20) }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        throw new Error(typeof data.error === 'string' ? data.error : `HTTP ${res.status}`);
      }
      setTurns((prev) => [...prev, { role: 'assistant', content: String(data.reply) }]);
    } catch (err) {
      setError(err instanceof Error ? err.message : t('failed'));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card className="flex h-[calc(100dvh-13rem)] min-h-[420px] flex-col">
      <CardContent className="flex min-h-0 flex-1 flex-col gap-3 p-4">
        {turns.length > 0 ? (
          <div className="flex justify-end">
            <Button variant="ghost" size="sm" onClick={startNewChat} disabled={busy}>
              <Plus className="h-4 w-4" /> {t('newChat')}
            </Button>
          </div>
        ) : null}
        <div ref={scrollerRef} className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
          {turns.length === 0 ? (
            <div className="flex flex-col items-center gap-5 py-4">
              <div className="flex flex-col items-center gap-2 text-center">
                <span className="border-border bg-muted/40 text-muted-foreground inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px]">
                  <Sparkles className="text-primary h-3 w-3" aria-hidden="true" />
                  {t('intro.badge')}
                </span>
                <h2 className="font-serif text-3xl leading-[1.1] text-foreground sm:text-4xl">
                  {firstName ? t('intro.greetingNamed', { name: firstName }) : t('intro.greeting')}
                </h2>
                <p className="text-muted-foreground max-w-md text-sm">{t('intro.subtitle')}</p>
              </div>

              <div className="grid w-full gap-3 sm:grid-cols-2">
                {IDEA_KEYS.map((key) => (
                  <button
                    key={key}
                    type="button"
                    onClick={() => pickIdea(t(`ideas.${key}.prompt`))}
                    className="border-border bg-card hover:border-primary/40 focus-visible:ring-ring group flex flex-col overflow-hidden rounded-xl border text-left transition-colors focus-visible:ring-2 focus-visible:outline-none"
                  >
                    <div className="border-border bg-muted/30 flex min-h-[84px] flex-col justify-center gap-1.5 border-b px-3 py-2.5">
                      <HermesIdeaPreview idea={key} />
                    </div>
                    <div className="flex flex-1 flex-col gap-1 px-3 py-2.5">
                      <span className="text-foreground text-sm font-semibold">{t(`ideas.${key}.title`)}</span>
                      <span className="text-muted-foreground text-xs">{t(`ideas.${key}.desc`)}</span>
                      <span className="text-primary mt-1 inline-flex items-center gap-1 text-xs font-medium">
                        {t(`ideas.${key}.cta`)}
                        <ArrowRight className="h-3 w-3 transition-transform group-hover:translate-x-0.5" aria-hidden="true" />
                      </span>
                    </div>
                  </button>
                ))}
              </div>
            </div>
          ) : (
            turns.map((turn, index) => (
              <div
                key={index}
                className={
                  turn.role === 'user'
                    ? 'ml-auto max-w-[85%] rounded-xl bg-primary px-3 py-2 text-sm text-primary-foreground whitespace-pre-wrap'
                    : 'mr-auto max-w-[90%] rounded-xl bg-muted px-3 py-2 text-sm text-foreground whitespace-pre-wrap'
                }
              >
                {turn.content}
              </div>
            ))
          )}
          {busy ? (
            <p className="flex items-center gap-2 text-xs text-muted-foreground">
              <Loader2 className="h-3.5 w-3.5 animate-spin" /> {t('thinking')}
            </p>
          ) : null}
          <div ref={bottomRef} />
        </div>

        {error ? <p className="text-xs text-destructive">{error}</p> : null}

        <div className="flex items-end gap-2">
          <Textarea
            ref={textareaRef}
            value={input}
            onChange={(event) => setInput(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                void send();
              }
            }}
            placeholder={t('placeholder')}
            className="min-h-11 flex-1 resize-none"
            disabled={busy}
          />
          <Button onClick={() => void send()} disabled={busy || !input.trim()} size="icon" aria-label={t('send')}>
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}


const IDEA_KEYS = ['cuadre', 'sinResponder', 'incidencia', 'semana'] as const;
type IdeaKey = (typeof IDEA_KEYS)[number];

/** Miniaturas sin cifras: muestran la forma del dato, nunca inventan números. */
function HermesIdeaPreview({ idea }: { idea: IdeaKey }) {
  if (idea === 'cuadre') {
    return (
      <>
        {['CRM', 'Finanzas', 'Semanal'].map((label, index) => (
          <div key={label} className="flex items-center gap-2 text-[11px] text-muted-foreground">
            <span className="bg-border h-1.5 w-1.5 rounded-full" aria-hidden="true" />
            <span>{label}</span>
            <ClipboardCheck
              className={index === 0 ? 'ml-auto h-3 w-3 text-muted-foreground' : 'ml-auto h-3 w-3 text-primary'}
              aria-hidden="true"
            />
          </div>
        ))}
      </>
    );
  }
  if (idea === 'sinResponder') {
    return (
      <>
        {[0, 1, 2].map((row) => (
          <div key={row} className="flex items-center gap-2">
            <span className="bg-muted h-4 w-4 rounded-full" aria-hidden="true" />
            <span className="bg-border h-1.5 flex-1 rounded-full" aria-hidden="true" style={{ maxWidth: `${62 - row * 10}%` }} />
            <span className="bg-border h-1.5 w-6 rounded-full" aria-hidden="true" />
          </div>
        ))}
      </>
    );
  }
  if (idea === 'incidencia') {
    return (
      <>
        <span className="inline-flex w-fit items-center gap-1 rounded-full bg-amber-500/15 px-2 py-0.5 text-[11px] font-medium text-amber-600 dark:text-amber-400">
          <AlertTriangle className="h-3 w-3" aria-hidden="true" />
          —
        </span>
        <div className="flex items-center gap-2">
          <span className="bg-border h-1.5 flex-1 rounded-full" aria-hidden="true" />
          <span className="bg-border h-1.5 w-8 rounded-full" aria-hidden="true" />
        </div>
      </>
    );
  }
  return (
    <div className="flex items-end gap-1" aria-hidden="true">
      {[38, 58, 46, 72, 54, 82, 30].map((height, index) => (
        <span
          key={index}
          className={index === 6 ? 'bg-muted w-2 rounded-t-sm' : 'bg-primary/70 w-2 rounded-t-sm'}
          style={{ height: `${height * 0.42}px` }}
        />
      ))}
    </div>
  );
}
