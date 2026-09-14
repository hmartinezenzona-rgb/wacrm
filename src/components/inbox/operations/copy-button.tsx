"use client";

import { useEffect, useRef, useState, type MouseEvent } from "react";
import { Check, Copy } from "lucide-react";
import { Button } from "@/components/ui/button";

interface CopyButtonProps {
  /** The raw value copied to the clipboard — never the display-formatted
   *  form (e.g. the unspaced card number, not the grouped-in-4s text). */
  value: string;
  ariaLabel: string;
}

const COPIED_RESET_MS = 1500;

/**
 * Small icon-only button that copies `value` to the clipboard and shows a
 * brief "copied" state (`data-copied`, swapped icon) for
 * `COPIED_RESET_MS` before reverting.
 */
export function CopyButton({ value, ariaLabel }: CopyButtonProps) {
  const [copied, setCopied] = useState(false);
  const resetTimeout = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (resetTimeout.current) clearTimeout(resetTimeout.current);
    };
  }, []);

  function handleCopy(event: MouseEvent<HTMLButtonElement>) {
    event.stopPropagation();

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

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon-xs"
      aria-label={ariaLabel}
      title={ariaLabel}
      data-copied={copied ? "true" : "false"}
      onClick={handleCopy}
    >
      {copied ? <Check aria-hidden="true" className="text-emerald-600" /> : <Copy aria-hidden="true" />}
    </Button>
  );
}
