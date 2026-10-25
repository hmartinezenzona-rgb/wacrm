'use client';

// ============================================================
// HermesChat — the admin's chat with Hermes inside the panel.
//
// Sends the whole short conversation to /api/hermes/chat (which proxies the
// Hermes API server); Hermes answers with its read-only CRM tools.
// ============================================================

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Loader2, Plus, Send } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';

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
    bottomRef.current?.scrollIntoView({ block: 'end' });
  }, [turns, busy]);

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
        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
          {turns.length === 0 ? (
            <p className="pt-6 text-center text-sm text-muted-foreground">{t('empty')}</p>
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
