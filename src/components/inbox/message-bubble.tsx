"use client";

import { useState, useEffect, useCallback, useRef, memo } from "react";
import { createPortal } from "react-dom";
import { cn } from "@/lib/utils";
import type { Message, MessageReaction } from "@/types";
import {
  Clock,
  Check,
  CheckCheck,
  XCircle,
  FileText,
  MapPin,
  LayoutTemplate,
  ImageOff,
  CornerDownLeft,
  Sparkles,
} from "lucide-react";
import { format } from "date-fns";
import { ReplyQuote } from "./reply-quote";
import { MessageReactions } from "./message-reactions";
import { InteractivePreview } from "@/components/interactive/interactive-preview";
import { useTranslations } from "next-intl";
import { WhatsAppText } from "@/lib/whatsapp/format";
import {
  invalidateSignedMedia,
  peekSignedMediaSrc,
  resolveMediaSrc,
} from "@/lib/storage/signed-media";
import { useMediaSrc } from "@/lib/storage/use-media-src";
import { chatMediaProxyUrl } from "@/lib/storage/chat-media";

interface MessageBubbleProps {
  message: Message;
  /** Pre-computed quote info for messages that reply to another. */
  reply?: { authorLabel: string; preview: string } | null;
  reactions?: MessageReaction[];
  currentUserId?: string;
  onToggleReaction?: (emoji: string) => void;
  /** Jump to the message this one replies to; absent when it is not loaded. */
  onJumpToReply?: () => void;
}

function StatusIcon({ status }: { status: Message["status"] }) {
  switch (status) {
    case "sending":
      return <Clock className="h-3 w-3 text-muted-foreground" />;
    case "sent":
      return <Check className="h-3 w-3 text-muted-foreground" />;
    case "delivered":
      return <CheckCheck className="h-3 w-3 text-muted-foreground" />;
    case "read":
      return <CheckCheck className="h-3 w-3 text-blue-400" />;
    case "failed":
      return <XCircle className="h-3 w-3 text-red-400" />;
    default:
      return null;
  }
}

function MediaUnavailable({ label, t }: { label: string, t: ReturnType<typeof useTranslations> }) {
  return (
    <div className="flex items-center gap-2 rounded-lg bg-muted/40 px-3 py-2 text-xs text-muted-foreground">
      <ImageOff className="h-4 w-4 shrink-0 text-muted-foreground" />
      <span>{t("unavailable", { label })}</span>
    </div>
  );
}

/** Sized placeholder so a lazy media box reserves layout before it loads. */
/**
 * Copy for a media bubble that has no pixels yet: still downloading, or given
 * up. Staff-facing only — nothing here is ever sent to the customer.
 */
function MediaStateBox({ label, tone }: { label: string; tone: "pending" | "failed" }) {
  return (
    <div
      className={
        tone === "failed"
          ? "flex h-40 w-60 flex-col items-center justify-center gap-2 rounded-lg bg-muted/60 px-3 text-center text-xs text-muted-foreground"
          : "flex h-40 w-60 flex-col items-center justify-center gap-2 rounded-lg bg-muted/40 px-3 text-center text-xs text-muted-foreground"
      }
    >
      <ImageOff className="h-5 w-5 opacity-70" />
      <span>{label}</span>
    </div>
  );
}

function MediaLoadingBox({ className }: { className?: string }) {
  return (
    <div
      className={
        className ??
        "flex h-40 w-60 items-center justify-center rounded-lg bg-muted"
      }
    >
      <div className="h-5 w-5 animate-spin rounded-full border-2 border-primary border-t-transparent" />
    </div>
  );
}

function MediaImage({
  url,
  alt,
  label,
  t,
  thumbPath,
  width,
  height,
  status,
}: {
  url: string;
  alt: string;
  label: string;
  t: ReturnType<typeof useTranslations>;
  /** Migration 400: the WebP sibling, the stored dimensions and the state. */
  thumbPath?: string | null;
  width?: number | null;
  height?: number | null;
  status?: "pending" | "ready" | "failed" | null;
}) {
  // Meta's media proxy needs the session cookie, so it is fetched as a blob.
  // chat-media objects get a signed CDN URL and never touch this server.
  const isMetaMedia = url.startsWith("/api/whatsapp/media/");
  // The bubble paints the small WebP when ingest stored one; the original is
  // only resolved when the user opens the full-size viewer.
  const thumbUrl = thumbPath ? chatMediaProxyUrl(thumbPath) : null;
  const [zoom, setZoom] = useState(false);
  const [src, setSrc] = useState<string | null>(null);
  // Set after one failed load: the re-signed URL, or the proxy fallback.
  const [override, setOverride] = useState<string | null>(null);
  const [error, setError] = useState(false);
  const thumbSrc = useMediaSrc(isMetaMedia ? null : thumbUrl);
  // Resolved only when the viewer opens: the bubble itself never pays for it.
  const zoomSrc = useMediaSrc(zoom && !isMetaMedia ? url : null);
  const signedSrc = useMediaSrc(isMetaMedia ? null : url);
  // A URL the server already seeded is paintable on the very first render, so
  // start settled instead of flashing the loading box for one commit.
  const [loading, setLoading] = useState(
    () => !isMetaMedia && peekSignedMediaSrc(url) === null,
  );
  const resignedRef = useRef(false);

  useEffect(() => {
    if (!isMetaMedia) {
      setError(false);
      setLoading(signedSrc === null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(false);
    (async () => {
      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error("Failed to load media");
        const blob = await res.blob();
        if (cancelled) return;
        setSrc(URL.createObjectURL(blob));
      } catch {
        if (!cancelled) setError(true);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [url, isMetaMedia, signedSrc]);

  useEffect(() => {
    return () => {
      if (src?.startsWith("blob:")) URL.revokeObjectURL(src);
    };
  }, [src]);

  // Close the fullscreen viewer with Escape.
  useEffect(() => {
    if (!zoom) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setZoom(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [zoom]);

  const displaySrc = isMetaMedia ? src : (override ?? thumbSrc ?? signedSrc);
  // The error handler compares against the source that just failed without
  // taking it as a dependency (which would rebuild the callback mid-flight).
  const displaySrcRef = useRef<string | null>(displaySrc);
  // Written in an effect, never during render: the only reader is the async
  // re-sign callback, which runs after effects flush.
  useEffect(() => {
    displaySrcRef.current = displaySrc;
  }, [displaySrc]);

  // A stale signature (opened past its TTL) fires `error`. Drop it and ask for
  // a new one exactly once. One failure must be enough to show the unavailable
  // state: React does not re-fire `error` when the `src` did not change, so if
  // the re-sign yields nothing new there is nothing left to wait for.
  const handleMediaError = useCallback(() => {
    if (isMetaMedia || resignedRef.current) {
      setError(true);
      return;
    }
    resignedRef.current = true;
    invalidateSignedMedia(url);
    void resolveMediaSrc(url).then((next) => {
      const fallback = next || null;
      if (!fallback || fallback === displaySrcRef.current) {
        setError(true);
        return;
      }
      setOverride(fallback);
    });
  }, [isMetaMedia, url]);

  if (error) {
    return status === "failed" ? (
      <MediaStateBox label={t("mediaFailed")} tone="failed" />
    ) : (
      <MediaUnavailable label={label} t={t} />
    );
  }

  // Nothing has been downloaded yet: say so, instead of an anonymous spinner.
  if (status === "pending") {
    return <MediaStateBox label={t("mediaPending")} tone="pending" />;
  }

  if (loading || displaySrc === null) {
    return <MediaLoadingBox />;
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setZoom(true)}
        aria-label={alt}
        className="block cursor-zoom-in"
      >
        <img
          src={displaySrc ?? ""}
          alt={alt}
          // Known dimensions reserve the exact box, so the thread does not
          // reflow when the pixels land. Unknown ones keep the old fixed box.
          width={width ?? undefined}
          height={height ?? undefined}
          loading="lazy"
          decoding="async"
          className={
            width && height
              ? "h-auto max-h-64 max-w-60 rounded-lg object-cover"
              : "h-40 w-60 rounded-lg object-cover"
          }
          onError={handleMediaError}
        />
      </button>

      {/* Rendered in a portal so the overlay is never clipped by the
          scrolling thread or by a transformed ancestor. Reuses the same
          blob/URL as the thumbnail: no extra request to Meta. */}
      {zoom &&
        typeof document !== "undefined" &&
        createPortal(
          <div
            role="dialog"
            aria-modal="true"
            aria-label={alt}
            onClick={() => setZoom(false)}
            className="fixed inset-0 z-[100] flex cursor-zoom-out items-center justify-center bg-black/80 p-4"
          >
            <img
              src={zoomSrc ?? displaySrc ?? ""}
              alt={alt}
              className="max-h-full max-w-full rounded-lg object-contain"
            />
          </div>,
          document.body,
        )}
    </>
  );
}

/**
 * A playable/openable chat-media source with the same recovery contract as
 * images: one error drops the stale signature and asks for one new URL, then
 * falls back to the proxy. When no different URL can be produced, the media is
 * unavailable on that first failure — a second `error` never fires for an
 * unchanged `src`.
 */
function useRecoverableMediaSrc(url: string | null | undefined) {
  const resolved = useMediaSrc(url ?? null);
  const [override, setOverride] = useState<string | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const resignedRef = useRef(false);
  const src = override ?? resolved;
  const srcRef = useRef<string | null>(src);
  // Written in an effect, never during render: the comparison only runs
  // inside the async re-sign callback, which executes after effects flush.
  useEffect(() => {
    srcRef.current = src;
  }, [src]);

  const onError = useCallback(() => {
    if (!url || resignedRef.current) {
      setUnavailable(true);
      return;
    }
    // One re-sign per element per mount: the ref makes a loop impossible.
    resignedRef.current = true;
    invalidateSignedMedia(url);
    void resolveMediaSrc(url).then((next) => {
      const fallback = next || null;
      if (!fallback || fallback === srcRef.current) {
        setUnavailable(true);
        return;
      }
      setOverride(fallback);
    });
  }, [url]);

  return { src, unavailable, onError };
}

function MessageContent({ message, t }: { message: Message, t: ReturnType<typeof useTranslations> }) {
  // Video, audio and the document link read chat-media through the same
  // recovery path as images: the signed URL is the only first source, a stale
  // one re-signs once, and the proxy is the fallback.
  const media = useRecoverableMediaSrc(message.media_url ?? null);
  switch (message.content_type) {
    case "text":
      return (
        <p className="whitespace-pre-wrap break-words text-sm">
          <WhatsAppText text={message.content_text ?? ""} />
        </p>
      );

    case "image":
      return (
        <div>
          {message.media_url ? (
            <MediaImage
              url={message.media_url}
              alt={t("sharedImageAlt")}
              label={t("photo")}
              t={t}
              thumbPath={message.media_thumb_path ?? null}
              width={message.media_width ?? null}
              height={message.media_height ?? null}
              status={message.media_status ?? null}
            />
          ) : (
            <MediaUnavailable label={t("photo")} t={t} />
          )}
          {message.content_text && (
            <p className="mt-1 whitespace-pre-wrap break-words text-sm">
              <WhatsAppText text={message.content_text ?? ""} />
            </p>
          )}
        </div>
      );

    case "video":
      return (
        <div>
          {message.media_url ? (
            media.unavailable ? (
              <MediaUnavailable label={t("video")} t={t} />
            ) : media.src ? (
              <video
                src={media.src}
                controls
                preload="none"
                className="max-h-64 max-w-60 rounded-lg"
                onError={media.onError}
              />
            ) : (
              <MediaLoadingBox />
            )
          ) : (
            <MediaUnavailable label={t("video")} t={t} />
          )}
          {message.content_text && (
            <p className="mt-1 whitespace-pre-wrap break-words text-sm">
              <WhatsAppText text={message.content_text ?? ""} />
            </p>
          )}
        </div>
      );

    case "audio":
      return (
        <div>
          {message.media_url ? (
            media.unavailable ? (
              <MediaUnavailable label={t("audio")} t={t} />
            ) : media.src ? (
              <audio
                src={media.src}
                controls
                preload="none"
                className="max-w-60"
                onError={media.onError}
              />
            ) : (
              <MediaLoadingBox />
            )
          ) : (
            <MediaUnavailable label={t("audio")} t={t} />
          )}
        </div>
      );

    case "document":
      if (!message.media_url || media.unavailable) {
        return <MediaUnavailable label={message.content_text || t("document")} t={t} />;
      }
      return (
        <a
          href={media.src ?? undefined}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-2 rounded-lg bg-muted/50 px-3 py-2 text-sm hover:bg-muted"
        >
          <FileText className="h-5 w-5 shrink-0 text-muted-foreground" />
          <span className="truncate">
            {message.content_text || t("document")}
          </span>
        </a>
      );

    case "template":
      return (
        <div>
          <span className="mb-1 inline-flex items-center gap-1 rounded bg-primary/20 px-1.5 py-0.5 text-[10px] font-medium text-primary">
            <LayoutTemplate className="h-3 w-3" />
            {t("template")}
          </span>
          {message.content_text && (
            <p className="mt-1 whitespace-pre-wrap break-words text-sm">
              <WhatsAppText text={message.content_text ?? ""} />
            </p>
          )}
        </div>
      );

    case "location":
      return (
        <div className="flex items-center gap-2 text-sm">
          <MapPin className="h-4 w-4 shrink-0 text-muted-foreground" />
          <span>{message.content_text || t("locationShared")}</span>
        </div>
      );

    case "interactive": {
      // Three cases share content_type='interactive':
      //  - OUTBOUND with payload (composer / automation / Flow send after
      //    migration 035): render the buttons/list as they appear on the phone.
      //  - INBOUND tap (customer chose an option, sender_type='customer'):
      //    no payload; show the tapped option's title with a reply affordance
      //    so agents can tell it's a tap, not the customer typing.
      //  - OUTBOUND with NO payload (legacy bot/Flow sends from before
      //    migration 035 backfilled the column): show the body text plainly —
      //    it is our own message, NOT a customer tap.
      if (message.interactive_payload) {
        return <InteractivePreview payload={message.interactive_payload} />;
      }
      if (message.sender_type === "customer") {
        return (
          <div className="flex flex-col gap-0.5">
            <span className="inline-flex items-center gap-1 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
              <CornerDownLeft className="h-3 w-3" />
              {t("buttonReply")}
            </span>
            <p className="whitespace-pre-wrap break-words text-sm">
              {message.content_text || t("interactiveReply")}
            </p>
          </div>
        );
      }
      return (
        <p className="whitespace-pre-wrap break-words text-sm">
          {message.content_text || t("interactiveReply")}
        </p>
      );
    }

    default:
      return (
        <p className="whitespace-pre-wrap break-words text-sm">
          {message.content_text || t("unsupported")}
        </p>
      );
  }
}

function MessageBubbleBase({
  message,
  reply,
  reactions,
  currentUserId,
  onToggleReaction,
  onJumpToReply,
}: MessageBubbleProps) {
  const t = useTranslations("Inbox.bubble");

  const isAgent = message.sender_type === "agent" || message.sender_type === "bot";
  const time = format(new Date(message.created_at), "HH:mm");

  // Row alignment + width cap are owned by <MessageActions> so its hover
  // group matches the bubble's content area, not the full row.
  return (
    <div
      className={cn(
        "flex flex-col",
        isAgent ? "items-end" : "items-start",
      )}
    >
      <div
        className={cn(
          "relative rounded-2xl px-3 py-2",
          isAgent
            ? "rounded-br-md bg-primary text-primary-foreground"
            : "rounded-bl-md border border-border bg-card text-foreground",
        )}
      >
        {reply && (
          <ReplyQuote
            authorLabel={reply.authorLabel}
            preview={reply.preview}
            onPrimary={isAgent}
            onActivate={onJumpToReply}
          />
        )}
        <MessageContent message={message} t={t} />
        <div
          className={cn(
            "mt-1 flex items-center gap-1",
            isAgent ? "justify-end" : "justify-start",
          )}
        >
          {/* AI badge — only on replies the auto-reply bot generated
              (always outbound, so it sits on the primary fill). Lets
              agents tell an AI reply from their own / a Flow's at a
              glance. */}
          {message.ai_generated && (
            <span
              // El fondo `/20` del propio texto ACLARABA la burbuja y dejaba el
              // distintivo en 4.05:1 — por debajo del minimo AA, y a 9px, que
              // es el texto mas pequeno de la app. Sin el tinte, la etiqueta
              // hereda el contraste de la burbuja y se sigue distinguiendo por
              // mayusculas, peso y tamano.
              className="inline-flex items-center gap-0.5 rounded-full px-1.5 py-px text-[9px] font-semibold uppercase leading-none tracking-wide text-primary-foreground"
              title={t("aiBadgeTitle")}
            >
              <Sparkles className="h-2.5 w-2.5" />
              {t("aiBadge")}
            </span>
          )}
          <span
            className={cn(
              "text-[10px]",
              // Outbound bubbles sit on the primary fill, so the
              // timestamp must read against that (not the neutral
              // foreground) — otherwise it goes low-contrast in light
              // mode. Inbound bubbles use the muted surface.
              isAgent ? "text-primary-foreground/90" : "text-muted-foreground",
            )}
          >
            {time}
          </span>
          {isAgent && <StatusIcon status={message.status} />}
        </div>
      </div>
      {reactions && reactions.length > 0 && onToggleReaction && (
        <MessageReactions
          reactions={reactions}
          currentUserId={currentUserId}
          onToggle={onToggleReaction}
        />
      )}
    </div>
  );
}

/**
 * Pure presenter, memoized so a parent state change never re-renders a bubble
 * whose props did not change. Callers must pass stable callbacks.
 */
export const MessageBubble = memo(MessageBubbleBase);
