'use client';

// ============================================================
// HermesChat — the admin's chat with Hermes inside the panel.
//
// Sends the whole short conversation to /api/hermes/chat (which proxies the
// Hermes API server); Hermes answers with its read-only CRM tools.
//
// Two layouts, one state: with no turns yet the screen is the greeting, the
// composer and the idea cards (the design the owner approved); once the
// conversation starts it becomes a fixed-height thread with the composer
// pinned underneath.
// ============================================================

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import {
  AlertTriangle,
  ArrowRight,
  ArrowUp,
  ClipboardCheck,
  ImagePlus,
  Info,
  Loader2,
  Plus,
  Sparkles,
  X,
} from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/hooks/use-auth';
import { MAX_IMAGE_BYTES, type HermesPart } from '@/lib/hermes/message-content';
import { compressImage } from '@/lib/hermes/compress-image';
import type { Vistazo } from '@/lib/hermes/vistazo';

interface Turn {
  role: 'user' | 'assistant';
  content: string;
  /**
   * Pixels of an attached image. Lives only in memory: persisting base64 into
   * sessionStorage would blow the tab's quota, so a reload keeps the text and
   * `hadImage` says a picture went with it.
   */
  imageUrl?: string;
  hadImage?: boolean;
}

// The conversation survives leaving the page and reloading the tab, so it is
// only lost when the admin presses "Nueva conversación" or closes the tab.
const STORAGE_KEY = 'wacrm.hermes.chat.v1';

function isTurn(value: unknown): value is Turn {
  if (!value || typeof value !== 'object') return false;
  const turn = value as Record<string, unknown>;
  return (turn.role === 'user' || turn.role === 'assistant') && typeof turn.content === 'string';
}

/** What the API receives: images travel as content parts, as Hermes expects. */
function toApiMessage(turn: Turn): { role: Turn['role']; content: string | HermesPart[] } {
  if (turn.role === 'user' && turn.imageUrl) {
    const parts: HermesPart[] = [];
    if (turn.content.trim()) parts.push({ type: 'text', text: turn.content });
    parts.push({ type: 'image_url', image_url: { url: turn.imageUrl } });
    return { role: 'user', content: parts };
  }
  return { role: turn.role, content: turn.content };
}

export function HermesChat() {
  const t = useTranslations('Hermes');
  const [turns, setTurns] = useState<Turn[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hintOpen, setHintOpen] = useState(true);
  const [attachment, setAttachment] = useState<string | null>(null);
  // The cards show the real figures; until they arrive they keep their drawing.
  const [vistazo, setVistazo] = useState<Vistazo | null>(null);
  const [attaching, setAttaching] = useState(false);
  const bottomRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const { profile } = useAuth();
  // El saludo va por el nombre de pila; sin perfil, saludo a secas.
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
        // Drop the pixels, keep the fact: a 1600px JPEG in base64 is ~1 MB and
        // sessionStorage holds about 5 MB for the whole tab.
        const light = turns.map(({ role, content, hadImage, imageUrl }) =>
          imageUrl ? { role, content, hadImage: true } : { role, content, hadImage },
        );
        sessionStorage.setItem(STORAGE_KEY, JSON.stringify(light));
      }
    } catch {
      // Storage full or blocked: the chat keeps working in memory.
    }
  }, [turns, loaded]);

  useEffect(() => {
    if (!loaded || turns.length > 0) return;
    let cancelled = false;
    fetch('/api/hermes/vistazo')
      .then((res) => (res.ok ? res.json() : null))
      .then((data: Vistazo | null) => {
        if (!cancelled && data) setVistazo(data);
      })
      .catch(() => {
        // The cards fall back to their drawing; nothing else breaks.
      });
    return () => {
      cancelled = true;
    };
  }, [loaded, turns.length]);

  useEffect(() => {
    // Only a running conversation follows its last turn. The greeting screen
    // scrolls with the page and must open at the top.
    if (turns.length === 0 && !busy) return;
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
    setAttachment(null);
    setError(null);
  }

  /** Prepare the picked picture and hold it until the question is sent. */
  async function attach(file: File | undefined) {
    if (!file || busy || attaching) return;
    setAttaching(true);
    setError(null);
    try {
      setAttachment(await compressImage(file, MAX_IMAGE_BYTES));
    } catch (err) {
      // Any failure ends the same for the admin: the picture was not attached.
      setError(t('attachFailed'));
    } finally {
      setAttaching(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  }

  async function send() {
    const text = input.trim();
    if ((!text && !attachment) || busy) return;
    const next: Turn[] = [...turns, { role: 'user', content: text, imageUrl: attachment ?? undefined }];
    setTurns(next);
    setInput('');
    setAttachment(null);
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/hermes/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ messages: next.slice(-20).map(toApiMessage) }),
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

  const composer = (
    <Composer
      value={input}
      onChange={setInput}
      onSend={() => void send()}
      busy={busy}
      textareaRef={textareaRef}
      fileInputRef={fileInputRef}
      attachment={attachment}
      attaching={attaching}
      onAttach={(file) => void attach(file)}
      onRemoveAttachment={() => setAttachment(null)}
    />
  );

  if (turns.length > 0 || busy) {
    return (
      <div className="border-border bg-card mx-auto flex h-[calc(100dvh-13rem)] min-h-[420px] w-full max-w-[900px] flex-col gap-3 rounded-xl border p-4">
        <div className="flex justify-end">
          <Button variant="ghost" size="sm" onClick={startNewChat} disabled={busy}>
            <Plus className="h-4 w-4" /> {t('newChat')}
          </Button>
        </div>
        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
          {turns.map((turn, index) => (
            <div
              key={index}
              className={
                turn.role !== 'user'
                  ? 'bg-muted text-foreground mr-auto max-w-[90%] rounded-xl px-3 py-2 text-sm whitespace-pre-wrap'
                  : turn.imageUrl || turn.hadImage
                    ? // A picture on a coloured bubble leaves a coloured frame around
                      // it; the neutral one lets the image stand on its own.
                      'bg-muted text-foreground ml-auto flex max-w-[85%] flex-col gap-1.5 rounded-xl px-2 py-2 text-sm'
                    : 'bg-primary text-primary-foreground ml-auto max-w-[85%] rounded-xl px-3 py-2 text-sm whitespace-pre-wrap'
              }
            >
              {turn.imageUrl ? (
                <img
                  src={turn.imageUrl}
                  alt={t('attachedImage')}
                  className="max-h-56 w-auto rounded-lg object-contain"
                />
              ) : turn.hadImage ? (
                <span className="text-[11px] opacity-80">{t('attachedImage')}</span>
              ) : null}
              {turn.content ? <span className="whitespace-pre-wrap">{turn.content}</span> : null}
            </div>
          ))}
          {busy ? (
            <p className="text-muted-foreground flex items-center gap-2 text-xs">
              <Loader2 className="h-3.5 w-3.5 animate-spin" /> {t('thinking')}
            </p>
          ) : null}
          <div ref={bottomRef} />
        </div>
        {error ? <p className="text-destructive text-xs">{error}</p> : null}
        {composer}
      </div>
    );
  }

  return (
    <div className="mx-auto flex w-full max-w-[900px] flex-col gap-6 py-2">
      <section className="flex flex-col items-start gap-2 text-left sm:items-center sm:text-center">
        <span className="border-border bg-card text-muted-foreground inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs">
          <Sparkles className="text-primary h-3.5 w-3.5" aria-hidden="true" />
          {t('intro.eyebrowFallback')}
        </span>
        <h2 className="font-serif text-foreground mt-0.5 text-[clamp(30px,5.4vw,46px)] leading-[1.08] tracking-[-0.01em] text-balance">
          {firstName ? t('intro.greetingNamed', { name: firstName }) : t('intro.greeting')}
        </h2>
        <p className="text-muted-foreground max-w-[46ch] text-[13.5px]">{t('intro.subtitle')}</p>
      </section>

      <section aria-label={t('placeholder')} className="flex flex-col gap-2.5">
        {composer}
        {hintOpen ? (
          <div className="border-border bg-muted/40 text-muted-foreground flex items-start gap-2.5 rounded-[14px] border py-[7px] pr-2.5 pl-3 text-xs sm:rounded-full">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
            <span>{t('hint.text')}</span>
            <button
              type="button"
              onClick={() => setHintOpen(false)}
              aria-label={t('hint.dismiss')}
              className="hover:text-foreground ml-auto shrink-0 rounded-full p-0.5"
            >
              <X className="h-3.5 w-3.5" aria-hidden="true" />
            </button>
          </div>
        ) : null}
      </section>

      <section aria-labelledby="hermes-ideas">
        <div className="flex flex-col gap-1">
          <span
            id="hermes-ideas"
            className="text-muted-foreground inline-flex items-center gap-1.5 text-[10.5px] font-semibold tracking-[0.1em] uppercase"
          >
            <Sparkles className="text-primary h-3.5 w-3.5" aria-hidden="true" />
            {t('ideas.heading')}
          </span>
          <p className="text-muted-foreground text-xs">{t('ideas.lead')}</p>
        </div>
        <div className="mt-3 grid gap-3.5 sm:grid-cols-2">
          {IDEA_KEYS.map((key) => (
            <button
              key={key}
              type="button"
              onClick={() => pickIdea(t(`ideas.${key}.prompt`))}
              className="border-border bg-card hover:border-border-strong focus-visible:ring-ring group flex flex-col overflow-hidden rounded-[14px] border text-left transition-[border-color,transform] duration-150 hover:-translate-y-px focus-visible:ring-2 focus-visible:outline-none"
            >
              <div className="border-border bg-muted/30 flex min-h-[104px] flex-col justify-center gap-[7px] border-b px-3.5 py-3">
                <HermesIdeaPreview idea={key} vistazo={vistazo} />
              </div>
              <div className="flex flex-1 flex-col gap-1.5 px-3.5 pt-3 pb-3.5">
                <span className="text-foreground text-[13.5px] font-semibold tracking-[-0.01em]">
                  {t(`ideas.${key}.title`)}
                </span>
                <span className="text-muted-foreground text-xs">{t(`ideas.${key}.desc`)}</span>
                <span className="text-primary mt-2 inline-flex items-center gap-1.5 text-xs font-medium">
                  {t(`ideas.${key}.cta`)}
                  <ArrowRight
                    className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5"
                    aria-hidden="true"
                  />
                </span>
              </div>
            </button>
          ))}
        </div>
      </section>

      {error ? <p className="text-destructive text-xs">{error}</p> : null}
    </div>
  );
}

const IDEA_KEYS = ['cuadre', 'sinResponder', 'incidencia', 'semana'] as const;

const thousands = (value: number): string =>
  new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(value);

/** Guyana time; the date too when the wait is older than today. */
function whenLabel(iso: string): string {
  const day = (d: Date) =>
    d.toLocaleDateString('en-CA', { timeZone: 'America/Guyana' });
  const time = (d: Date) =>
    d.toLocaleTimeString('es', {
      hour: '2-digit',
      minute: '2-digit',
      timeZone: 'America/Guyana',
    });
  const date = new Date(iso);
  return day(date) === day(new Date())
    ? time(date)
    : `${date.toLocaleDateString('es', { day: '2-digit', month: '2-digit', timeZone: 'America/Guyana' })} ${time(date)}`;
}
type IdeaKey = (typeof IDEA_KEYS)[number];

function Composer({
  value,
  onChange,
  onSend,
  busy,
  textareaRef,
  fileInputRef,
  attachment,
  attaching,
  onAttach,
  onRemoveAttachment,
}: {
  value: string;
  onChange: (value: string) => void;
  onSend: () => void;
  busy: boolean;
  textareaRef: React.RefObject<HTMLTextAreaElement | null>;
  fileInputRef: React.RefObject<HTMLInputElement | null>;
  attachment: string | null;
  attaching: boolean;
  onAttach: (file: File | undefined) => void;
  onRemoveAttachment: () => void;
}) {
  const t = useTranslations('Hermes');
  return (
    <div className="border-border-strong bg-card focus-within:border-primary flex flex-col gap-2.5 rounded-[20px] border px-3.5 pt-3 pb-2.5 shadow-sm transition-colors">
      <Textarea
        ref={textareaRef}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            onSend();
          }
        }}
        placeholder={t('placeholder')}
        className="min-h-[62px] resize-none border-0 bg-transparent px-0 py-0 shadow-none focus-visible:ring-0 dark:bg-transparent"
        disabled={busy}
      />
      {attachment ? (
        <div className="flex items-center gap-2">
          <img
            src={attachment}
            alt={t('attachedImage')}
            className="border-border h-12 w-12 rounded-md border object-cover"
          />
          <button
            type="button"
            onClick={onRemoveAttachment}
            aria-label={t('removeAttachment')}
            className="text-muted-foreground hover:text-foreground rounded-full p-1"
          >
            <X className="h-4 w-4" aria-hidden="true" />
          </button>
        </div>
      ) : null}
      <div className="flex items-center gap-2">
        <input
          ref={fileInputRef}
          type="file"
          accept="image/jpeg,image/png,image/webp"
          className="hidden"
          onChange={(event) => onAttach(event.target.files?.[0])}
        />
        <Button
          variant="outline"
          onClick={() => fileInputRef.current?.click()}
          disabled={busy || attaching}
          size="icon"
          className="h-8 w-8 rounded-full"
          aria-label={t('attach')}
        >
          {attaching ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <ImagePlus className="h-4 w-4" />
          )}
        </Button>
        <Button
          onClick={onSend}
          disabled={busy || (!value.trim() && !attachment)}
          size="icon"
          className="ml-auto h-8 w-8 rounded-full"
          aria-label={t('send')}
        >
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowUp className="h-4 w-4" />}
        </Button>
      </div>
    </div>
  );
}

/** Real figures when the panel can read them, the abstract drawing otherwise. */
function HermesIdeaPreview({ idea, vistazo }: { idea: IdeaKey; vistazo: Vistazo | null }) {
  if (idea === 'cuadre' && vistazo?.cuadre) {
    const { completadas, conLinea, sinLinea } = vistazo.cuadre;
    return (
      <>
        <div className="flex items-baseline gap-1.5">
          <span className="text-foreground font-mono text-xl font-semibold">{completadas}</span>
          <span className="text-muted-foreground text-[11.5px]">completadas hoy</span>
        </div>
        <div className="text-muted-foreground flex items-center gap-2 text-[11.5px]">
          <span>Finanzas</span>
          <span className="text-foreground ml-auto font-mono">{conLinea} líneas</span>
        </div>
        <div className="flex items-center gap-2 text-[11.5px]">
          <span className="text-muted-foreground">Sin línea</span>
          <span
            className={
              sinLinea > 0
                ? 'ml-auto font-mono text-amber-600 dark:text-amber-400'
                : 'text-foreground ml-auto font-mono'
            }
          >
            {sinLinea}
          </span>
        </div>
      </>
    );
  }
  if (idea === 'sinResponder' && vistazo?.sinResponder) {
    const { conversaciones, masAntiguo } = vistazo.sinResponder;
    return (
      <>
        <div className="flex items-baseline gap-1.5">
          <span className="text-foreground font-mono text-xl font-semibold">{conversaciones}</span>
          <span className="text-muted-foreground text-[11.5px]">esperando respuesta</span>
        </div>
        {masAntiguo ? (
          <div className="text-muted-foreground flex items-center gap-2 text-[11.5px]">
            <span>La más antigua</span>
            <span className="text-foreground ml-auto font-mono">{whenLabel(masAntiguo)}</span>
          </div>
        ) : null}
      </>
    );
  }
  if (idea === 'incidencia' && vistazo?.incidencias) {
    const { operaciones, importeGyd } = vistazo.incidencias;
    if (operaciones === 0) {
      // Nothing stopped: a plain zero reads better than an empty warning.
      return (
        <div className="flex items-baseline gap-1.5">
          <span className="text-foreground font-mono text-xl font-semibold">0</span>
          <span className="text-muted-foreground text-[11.5px]">en incidencia</span>
        </div>
      );
    }
    return (
      <>
        <span className="inline-flex w-fit items-center gap-1.5 rounded-full bg-amber-500/15 px-2.5 py-0.5 text-[11px] font-medium text-amber-600 dark:text-amber-400">
          <AlertTriangle className="h-3 w-3" aria-hidden="true" />
          {operaciones} en incidencia
        </span>
        <div className="text-muted-foreground flex items-center gap-2 text-[11.5px]">
          <span>Importe parado</span>
          <span className="text-foreground ml-auto font-mono">{thousands(importeGyd)} GYD</span>
        </div>
      </>
    );
  }
  if (idea === 'semana' && vistazo?.semana) {
    const { facturadoGyd, invertidoGyd, retornoGyd } = vistazo.semana;
    return (
      <>
        {[
          ['Facturado', facturadoGyd],
          ['Invertido', invertidoGyd],
          ['Retorno', retornoGyd],
        ].map(([label, value]) => (
          <div key={String(label)} className="text-muted-foreground flex items-center gap-2 text-[11.5px]">
            <span>{label}</span>
            <span className="text-foreground ml-auto font-mono">{thousands(Number(value))} GYD</span>
          </div>
        ))}
      </>
    );
  }
  if (idea === 'cuadre') {
    return (
      <>
        {['CRM', 'Finanzas', 'Semanal'].map((label, index) => (
          <div key={label} className="text-muted-foreground flex items-center gap-2 text-[11.5px]">
            <span className="bg-border h-1.5 w-1.5 rounded-full" aria-hidden="true" />
            <span>{label}</span>
            <ClipboardCheck
              className={
                index === 0
                  ? 'text-muted-foreground ml-auto h-3 w-3'
                  : 'text-primary ml-auto h-3 w-3'
              }
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
            <span className="bg-muted h-[18px] w-[18px] rounded-full" aria-hidden="true" />
            <span
              className="bg-border h-1.5 flex-1 rounded-full"
              aria-hidden="true"
              style={{ maxWidth: `${62 - row * 10}%` }}
            />
            <span className="bg-border h-1.5 w-6 rounded-full" aria-hidden="true" />
          </div>
        ))}
      </>
    );
  }
  if (idea === 'incidencia') {
    return (
      <>
        <span className="inline-flex w-fit items-center gap-1.5 rounded-full bg-amber-500/15 px-2.5 py-0.5 text-[11px] font-medium text-amber-600 dark:text-amber-400">
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
