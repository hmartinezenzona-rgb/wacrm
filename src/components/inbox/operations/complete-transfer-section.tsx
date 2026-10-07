"use client";

// ============================================================
// "Complete transfer" — the inline section that replaces the button
// (panel-23). Presentational only: it holds no draft, calls nothing
// itself, and reports every interaction upward. `CompleteTransferContainer`
// owns the draft, the network calls, and the `deliverDeal` run.
// ============================================================

import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { NotifyToggle } from "./notify-toggle";
import { DeliveryProofPanel } from "@/components/pipelines/delivery-proof";
import { PROOF_MAX_BYTES, type ProofImageKind, type ProofRejection } from "@/lib/pipelines/delivery-proof";

const MAX_MB = Math.round(PROOF_MAX_BYTES / 1024 / 1024);

/**
 * One result line, shown below the checkbox. `"warning"` is the
 * closed-window case — it always carries an action ("Complete anyway");
 * `"error"` covers every failure, with an action only when a retry is
 * safe (a stage-only retry, or the exact same attempt again).
 */
export type CompleteTransferBanner =
  | { kind: "warning"; text: string; action: { label: string; onClick: () => void } }
  | { kind: "error"; text: string; action?: { label: string; onClick: () => void } };

export interface CompleteTransferSectionProps {
  /** Only Zelle transfers show the note field — see `showCaption` on
   *  `DeliveryProofPanel`. */
  showCaption: boolean;
  file: File | null;
  previewUrl: string | null;
  caption: string;
  onFileAccepted: (file: File, kind: ProofImageKind) => void;
  onFileRejected: (reason: ProofRejection) => void;
  onCaptionChange: (caption: string) => void;
  onClear: () => void;
  skipChecked: boolean;
  onSkipChange: (checked: boolean) => void;
  busy: boolean;
  canSend: boolean;
  banner: CompleteTransferBanner | null;
  onCancel: () => void;
  onSubmit: () => void;
  /** Notify-customer bell; rendered only when `onNotifyChange` is given. */
  notify?: boolean;
  onNotifyChange?: (notify: boolean) => void;
}

export function CompleteTransferSection({
  showCaption,
  file,
  previewUrl,
  caption,
  onFileAccepted,
  onFileRejected,
  onCaptionChange,
  onClear,
  skipChecked,
  onSkipChange,
  busy,
  canSend,
  banner,
  onCancel,
  onSubmit,
  notify = true,
  onNotifyChange,
}: CompleteTransferSectionProps) {
  const t = useTranslations("Inbox.operationsPanel.completeTransfer");
  const tCommon = useTranslations("Inbox.operationsPanel");
  const locked = busy || !canSend;
  const submitLabel = !file || skipChecked ? t("complete") : t("sendAndComplete");

  return (
    <div
      className="space-y-2 rounded-lg border border-border bg-muted/30 p-3"
      onKeyDown={busy ? undefined : cancelOnEscape(onCancel)}
    >
      <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
        {t("title")}
      </p>

      <DeliveryProofPanel
        file={file}
        previewUrl={previewUrl}
        caption={caption}
        onFileAccepted={onFileAccepted}
        onFileRejected={onFileRejected}
        onCaptionChange={onCaptionChange}
        onClear={onClear}
        window={null}
        busy={busy}
        canSend={canSend}
        showCaption={showCaption}
        variant="compact"
        labels={{
          dropHint: t("proof.dropHint"),
          dropFormats: t("proof.dropFormats", { mb: MAX_MB }),
          removeAria: t("proof.removeAria"),
        }}
      />

      <label className="flex items-center gap-2 text-xs text-foreground">
        <input
          type="checkbox"
          checked={skipChecked}
          disabled={locked}
          onChange={(e) => onSkipChange(e.target.checked)}
        />
        {t("withoutScreenshot")}
      </label>

      {banner && (
        <p
          role={banner.kind === "warning" ? "status" : "alert"}
          className={
            banner.kind === "warning"
              ? "rounded-md bg-amber-500/10 px-2 py-1.5 text-[11px] leading-relaxed text-amber-500"
              : "rounded-md bg-destructive/10 px-2 py-1.5 text-[11px] leading-relaxed text-destructive"
          }
        >
          {banner.text}
          {banner.action && (
            <Button
              type="button"
              variant="ghost"
              size="xs"
              className="ml-2"
              disabled={busy}
              onClick={banner.action.onClick}
            >
              {banner.action.label}
            </Button>
          )}
        </p>
      )}

      <ConfirmCancelButtons
        onCancel={onCancel}
        onConfirm={onSubmit}
        cancelLabel={tCommon("cancel")}
        confirmLabel={submitLabel}
        pending={busy}
        confirmDisabled={!canSend}
      >
        {onNotifyChange && <NotifyToggle notify={notify} onChange={onNotifyChange} disabled={locked} />}
      </ConfirmCancelButtons>

    </div>
  );
}
