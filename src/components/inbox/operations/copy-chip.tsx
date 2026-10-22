"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";

interface CopyChipProps {
  /** The raw value copied to the clipboard — never the display-formatted
   *  form (e.g. the unspaced card number, not the grouped-in-4s text). */
  value: string;
  /** What's shown in the chip's body; defaults to `value` when omitted. */
  display?: ReactNode;
  /** Small (14px) leading icon, muted. */
  icon?: ReactNode;
  ariaLabel: string;
  /** Right-aligned, muted hint (e.g. "calculated ÷120" or a lock icon). */
  hint?: ReactNode;
  tone?: "default" | "warning";
  /** When given, click calls this instead of copying `value` — used for
   *  the "Amount missing · add" chip, which opens the correction form. */
  onActivate?: () => void;
  disabled?: boolean;
}

const COPIED_RESET_MS = 1200;

/**
 * Full-width tap-to-copy row used throughout the "Deliver to" block. By
 * default, tapping copies `value` to the clipboard and shows a transient
 * "Copied ✓" state (`aria-live="polite"`) for `COPIED_RESET_MS` before
 * reverting. When `onActivate` is given, tapping calls it instead and the
 * clipboard is never touched (e.g. the amount-missing warning chip opens
 * the operation correction form).
 */
export function CopyChip({
  value,
  display,
  icon,
  ariaLabel,
  hint,
  tone = "default",
  onActivate,
  disabled = false,
}: CopyChipProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [copied, setCopied] = useState(false);
  const resetTimeout = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (resetTimeout.current) clearTimeout(resetTimeout.current);
    };
  }, []);

  function handleClick() {
    if (onActivate) {
      onActivate();
      return;
    }

    if (resetTimeout.current) {
      clearTimeout(resetTimeout.current);
      resetTimeout.current = null;
    }

    navigator.clipboard
      ?.writeText(value)
      .then(() => {
        setCopied(true);
        resetTimeout.current = setTimeout(() => setCopied(false), COPIED_RESET_MS);
      })
      .catch(() => {});
  }

  const toneClassName =
    tone === "warning"
      ? "bg-amber-100 text-amber-900 dark:bg-amber-500/15 dark:text-amber-200"
      : "bg-muted text-foreground";

  return (
    <button
      type="button"
      aria-label={ariaLabel}
      title={ariaLabel}
      data-tone={tone}
      disabled={disabled}
      onClick={handleClick}
      className={`flex min-h-8 w-full cursor-pointer items-center gap-1.5 rounded-lg px-2 py-1 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-60 ${toneClassName}`}
    >
      {copied ? (
        <span aria-live="polite" className="font-mono text-xs">
          {t("copied")}
        </span>
      ) : (
        <>
          {icon && (
            <span className="flex size-3.5 shrink-0 items-center justify-center text-muted-foreground">
              {icon}
            </span>
          )}
          <span className="min-w-0 flex-1 break-words font-mono text-xs">{display ?? value}</span>
          {hint && <span className="shrink-0 text-[10px] text-muted-foreground">{hint}</span>}
        </>
      )}
    </button>
  );
}
