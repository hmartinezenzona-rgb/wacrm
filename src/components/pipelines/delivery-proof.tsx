"use client";

// ============================================================
// The "Prueba de entrega" panel inside the deal sheet.
//
// Presentational on purpose: it holds no draft of its own, uploads
// nothing, sends nothing and writes nothing. It reports a chosen
// file upwards and renders whatever the parent hands back. Every
// side effect belongs to the board, which is the only place that
// knows whether the deal is actually being delivered.
//
// The file is kept in memory until the operator confirms the
// delivery — it is NOT uploaded on paste. `chat-media` is a public
// bucket, so a screenshot of a bank transfer must not land on an
// unauthenticated URL merely because someone pressed Ctrl+V and
// then changed their mind.
// ============================================================

import { useCallback, useRef, useState } from "react";
import { ImageUp, Loader2, Paperclip, X } from "lucide-react";
import { useTranslations } from "next-intl";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  PROOF_ACCEPTED_MIME,
  PROOF_MAX_BYTES,
  pickPastedImage,
  validateProofFile,
  type ProofImageKind,
  type ProofRejection,
} from "@/lib/pipelines/delivery-proof";
import type { SessionWindow } from "@/lib/inbox/session-window";

export interface DeliveryProofPanelProps {
  /** The file currently prepared, or null for the empty state. */
  file: File | null;
  /** Object URL for the thumbnail; owned and revoked by the parent. */
  previewUrl: string | null;
  caption: string;
  /** A validated file was chosen. The parent creates/replaces the draft. */
  onFileAccepted: (file: File, kind: ProofImageKind) => void;
  /** A file was chosen and refused; the parent shows the reason. */
  onFileRejected: (reason: ProofRejection) => void;
  onCaptionChange: (caption: string) => void;
  onClear: () => void;
  /**
   * The 24-hour window for this deal's conversation, or null while it
   * is still being looked up.
   */
  window: SessionWindow | null;
  /** True while a delivery is in flight — the panel goes read-only. */
  busy?: boolean;
  /** False for roles that cannot send messages. */
  canSend?: boolean;
}

const MAX_MB = Math.round(PROOF_MAX_BYTES / 1024 / 1024);

function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function DeliveryProofPanel({
  file,
  previewUrl,
  caption,
  onFileAccepted,
  onFileRejected,
  onCaptionChange,
  onClear,
  window: sessionWindow,
  busy = false,
  canSend = true,
}: DeliveryProofPanelProps) {
  const t = useTranslations("Pipelines.deliveryProof");
  const inputRef = useRef<HTMLInputElement>(null);
  const [checking, setChecking] = useState(false);
  const [dragOver, setDragOver] = useState(false);

  const locked = busy || !canSend;

  // One entry point for every way a file can arrive — paste, drop,
  // picker — so the rules cannot diverge between them.
  const accept = useCallback(
    async (candidate: File | null | undefined) => {
      if (!candidate || locked) return;
      setChecking(true);
      try {
        const result = await validateProofFile(candidate);
        if (result.ok) onFileAccepted(candidate, result.kind);
        else onFileRejected(result.reason);
      } finally {
        setChecking(false);
      }
    },
    [locked, onFileAccepted, onFileRejected],
  );

  // Ctrl+V. A paste carrying no image is left entirely alone so that
  // typing a note and pasting text into it keeps working.
  const handlePaste = useCallback(
    (e: React.ClipboardEvent) => {
      if (locked) return;
      const image = pickPastedImage(e.clipboardData);
      if (!image) return;
      e.preventDefault();
      void accept(image);
    },
    [accept, locked],
  );

  // File drop is scoped to this box only. Making the Kanban card a
  // drop target would fight @dnd-kit, which owns pointer events there.
  const handleDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setDragOver(false);
      if (locked) return;
      void accept(e.dataTransfer?.files?.[0]);
    },
    [accept, locked],
  );

  const windowClosed = sessionWindow?.expired === true;

  return (
    <div className="grid gap-2 rounded-lg border border-border bg-muted/40 p-3">
      <div className="flex items-center gap-2">
        <Paperclip className="h-3.5 w-3.5 text-muted-foreground" />
        <p className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
          {t("title")}
        </p>
      </div>

      {!file ? (
        <div
          role="button"
          tabIndex={locked ? -1 : 0}
          aria-disabled={locked}
          onPaste={handlePaste}
          onClick={() => !locked && inputRef.current?.click()}
          onKeyDown={(e) => {
            if (locked) return;
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              inputRef.current?.click();
            }
          }}
          onDragOver={(e) => {
            e.preventDefault();
            if (!locked) setDragOver(true);
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={handleDrop}
          className={`flex flex-col items-center justify-center gap-1 rounded-lg border-2 border-dashed px-3 py-6 text-center text-xs transition-colors ${
            locked
              ? "cursor-not-allowed border-border/50 text-muted-foreground/50"
              : dragOver
                ? "cursor-pointer border-primary bg-primary/5 text-foreground"
                : "cursor-pointer border-border text-muted-foreground hover:border-primary/50 hover:bg-muted"
          }`}
        >
          {checking ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <ImageUp className="h-4 w-4" />
          )}
          <span>{t("dropPaste")}</span>
          <span>{t("dropOr")}</span>
          <span className="text-[11px] text-muted-foreground/70">
            {t("dropFormats", { mb: MAX_MB })}
          </span>
        </div>
      ) : (
        <div className="flex items-start gap-3 rounded-lg border border-border bg-card p-2">
          {previewUrl ? (
            // Deliberately a plain <img>: the source is a blob: URL for
            // a file that has not been uploaded anywhere, which
            // next/image cannot optimise and should not try to.
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={previewUrl}
              alt={t("previewAlt")}
              className="h-16 w-16 shrink-0 rounded-md border border-border object-cover"
            />
          ) : (
            <div className="flex h-16 w-16 shrink-0 items-center justify-center rounded-md border border-border bg-muted">
              <ImageUp className="h-4 w-4 text-muted-foreground" />
            </div>
          )}
          <div className="min-w-0 flex-1">
            <p className="truncate text-xs font-medium text-foreground">
              {t("fileLabel", { size: humanSize(file.size) })}
            </p>
            <div className="mt-1 flex gap-2 text-xs">
              <button
                type="button"
                disabled={locked}
                onClick={() => inputRef.current?.click()}
                className="text-primary hover:underline disabled:opacity-50 disabled:hover:no-underline"
              >
                {t("change")}
              </button>
              <button
                type="button"
                disabled={locked}
                onClick={onClear}
                className="text-muted-foreground hover:text-foreground disabled:opacity-50"
              >
                {t("remove")}
              </button>
            </div>
          </div>
          <button
            type="button"
            disabled={locked}
            onClick={onClear}
            aria-label={t("removeAria")}
            className="rounded p-1 text-muted-foreground hover:bg-muted hover:text-foreground disabled:opacity-50"
          >
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      <input
        ref={inputRef}
        type="file"
        accept={PROOF_ACCEPTED_MIME.join(",")}
        className="hidden"
        onChange={(e) => {
          void accept(e.target.files?.[0]);
          // Reset so choosing the same file twice in a row still fires.
          e.target.value = "";
        }}
      />

      {file && (
        <div className="grid gap-1.5">
          <Label className="text-muted-foreground">{t("noteLabel")}</Label>
          <Textarea
            value={caption}
            disabled={locked}
            onChange={(e) => onCaptionChange(e.target.value)}
            onPaste={handlePaste}
            placeholder={t("notePlaceholder")}
            className="min-h-[60px] border-border bg-muted text-foreground"
          />
          <p className="text-[11px] text-muted-foreground">{t("noteHint")}</p>
        </div>
      )}

      {/* The window state is shown while the proof is being prepared,
          not only at confirm time — finding out the image cannot be
          sent AFTER dragging is the surprise worth avoiding. */}
      {sessionWindow &&
        (windowClosed ? (
          <p className="rounded-md bg-amber-500/10 px-2 py-1.5 text-[11px] leading-relaxed text-amber-500">
            ⚠ {t("windowClosed")}
          </p>
        ) : (
          <p className="text-[11px] text-muted-foreground">
            ✓{" "}
            {sessionWindow.state === "open" && sessionWindow.hoursLeft > 0
              ? t("windowOpenHours", { hours: sessionWindow.hoursLeft })
              : t("windowOpen")}
          </p>
        ))}

      {!canSend ? (
        <p className="text-[11px] text-muted-foreground">{t("noPermission")}</p>
      ) : (
        file && (
          <p className="text-[11px] text-muted-foreground">{t("willSend")}</p>
        )
      )}
    </div>
  );
}
