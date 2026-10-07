"use client";

import type { KeyboardEvent, ReactNode } from "react";
import { useTranslations } from "next-intl";
import { Check, Loader2, X } from "lucide-react";
import { Button } from "@/components/ui/button";

interface ConfirmCancelButtonsProps {
  /** Omit when there is nothing to go back to (the X is then not rendered). */
  onCancel?: () => void;
  /** Click handler of the check; leave out when `type="submit"` and the form owns the submit. */
  onConfirm?: () => void;
  /** `submit` makes the check submit the surrounding form (Enter then works for free). */
  type?: "button" | "submit";
  /** Accessible name and tooltip of the check. Default: the catalog's "Save". */
  confirmLabel?: string;
  /** Accessible name and tooltip of the X. Default: the catalog's "Cancel". */
  cancelLabel?: string;
  /** Request in flight: both buttons lock and the check shows a spinner. */
  pending?: boolean;
  /** Locks the check only (missing input, nothing to send). */
  confirmDisabled?: boolean;
  /** Extra controls placed before the X, e.g. the notify bell. */
  children?: ReactNode;
}

/**
 * The one save / confirm / cancel pair of the operations panel: ghost icon
 * buttons, X (muted) first, then the check (emerald, no solid fill). Icon-only,
 * so each carries an aria-label + title; a 32px hit area; the base button
 * supplies the visible focus ring.
 */
export function ConfirmCancelButtons({
  onCancel,
  onConfirm,
  type = "button",
  confirmLabel,
  cancelLabel,
  pending = false,
  confirmDisabled = false,
  children,
}: ConfirmCancelButtonsProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const confirmText = confirmLabel ?? t("save");
  const cancelText = cancelLabel ?? t("cancel");

  return (
    <div className="ml-auto flex w-fit shrink-0 items-center gap-0.5">
      {children}
      {onCancel && (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          aria-label={cancelText}
          title={cancelText}
          className="text-muted-foreground"
          onClick={onCancel}
          disabled={pending}
        >
          <X aria-hidden="true" />
        </Button>
      )}
      <Button
        type={type}
        variant="ghost"
        size="icon"
        aria-label={confirmText}
        title={confirmText}
        aria-busy={pending || undefined}
        className="text-emerald-600 hover:bg-emerald-500/10 hover:text-emerald-700 dark:text-emerald-400 dark:hover:bg-emerald-500/10 dark:hover:text-emerald-300"
        onClick={type === "button" ? onConfirm : undefined}
        disabled={pending || confirmDisabled}
      >
        {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : <Check aria-hidden="true" />}
      </Button>
    </div>
  );
}

/**
 * `onKeyDown` for an edit form or block: Escape cancels. Only keys typed inside
 * the form count; a popup portaled out of it (the app's Select) keeps its own
 * Escape, because React events bubble through portals but the DOM does not.
 */
export function cancelOnEscape(onCancel: () => void) {
  return (event: KeyboardEvent<HTMLElement>) => {
    if (event.key !== "Escape") return;
    if (!event.currentTarget.contains(event.target as Node)) return;
    event.preventDefault();
    onCancel();
  };
}
