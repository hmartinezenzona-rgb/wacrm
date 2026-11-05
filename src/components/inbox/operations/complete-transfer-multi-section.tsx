"use client";

// ============================================================
// "Complete transfer" for a 2+-beneficiary remesa (per-beneficiary
// delivery proof, P3). One `DeliveryProofPanel` per current beneficiary
// — the caption box only on the Zelle ones, exactly like the
// single-beneficiary section — under one shared skip-screenshot
// checkbox and submit/cancel row: skipping bypasses every beneficiary's
// proof at once, the same "complete without screenshot" escape hatch
// the single-beneficiary path has always had.
//
// Presentational only, same split as `CompleteTransferSection`: it holds
// no draft, uploads nothing, sends nothing. `CompleteTransferContainer`
// owns the per-beneficiary drafts and the send/register/deliver run.
// ============================================================

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { NotifyToggle } from "./notify-toggle";
import { DeliveryProofPanel } from "@/components/pipelines/delivery-proof";
import { PROOF_MAX_BYTES, type ProofImageKind, type ProofRejection } from "@/lib/pipelines/delivery-proof";
import type { CompleteTransferBanner } from "./complete-transfer-section";

const MAX_MB = Math.round(PROOF_MAX_BYTES / 1024 / 1024);

export interface CompleteTransferProofItem {
  beneficiaryId: string;
  /** Ordinal label ("Beneficiary 1") — beneficiaries carry no operator-
   *  facing display name here on purpose: same reasoning as the generic
   *  upload filename (`delivery-proof.ts`), one less place a customer's
   *  name has to be kept correct. */
  label: string;
  /** Only the Zelle beneficiaries show the note field — see `showCaption`
   *  on `DeliveryProofPanel`. */
  showCaption: boolean;
  file: File | null;
  previewUrl: string | null;
  caption: string;
  onFileAccepted: (file: File, kind: ProofImageKind) => void;
  onFileRejected: (reason: ProofRejection) => void;
  onCaptionChange: (caption: string) => void;
  onClear: () => void;
}

export interface CompleteTransferMultiSectionProps {
  items: CompleteTransferProofItem[];
  skipChecked: boolean;
  onSkipChange: (checked: boolean) => void;
  busy: boolean;
  canSend: boolean;
  /** False while any beneficiary is still missing its file and the
   *  operator hasn't chosen to skip — the submit button stays disabled
   *  rather than letting a partial submit reach the container. */
  canSubmit: boolean;
  banner: CompleteTransferBanner | null;
  onCancel: () => void;
  onSubmit: () => void;
  /** Notify-customer bell; rendered only when `onNotifyChange` is given. */
  notify?: boolean;
  onNotifyChange?: (notify: boolean) => void;
  /** Optional block under the title (the CUP inventory plan); the section never depends on it. */
  extra?: ReactNode;
  /** Part of a mixed-send sheet: no title, skip checkbox, notify bell or confirm/cancel row (the sheet owns them). */
  hideActions?: boolean;
}

export function CompleteTransferMultiSection({
  items,
  skipChecked,
  onSkipChange,
  busy,
  canSend,
  canSubmit,
  banner,
  onCancel,
  onSubmit,
  notify = true,
  onNotifyChange,
  extra,
  hideActions = false,
}: CompleteTransferMultiSectionProps) {
  const t = useTranslations("Inbox.operationsPanel.completeTransfer");
  const tCommon = useTranslations("Inbox.operationsPanel");
  const locked = busy || !canSend;
  const submitLabel = skipChecked ? t("complete") : t("sendAndComplete");

  return (
    <div
      className="space-y-2 rounded-lg border border-border bg-muted/30 p-3"
      onKeyDown={busy ? undefined : cancelOnEscape(onCancel)}
    >
      {!hideActions && (
        <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
          {t("title")}
        </p>
      )}

      {extra}

      <div className="space-y-3">
        {items.map((item) => (
          <div key={item.beneficiaryId} className="space-y-1">
            <p className="text-[11px] font-medium text-muted-foreground">{item.label}</p>
            <DeliveryProofPanel
              file={item.file}
              previewUrl={item.previewUrl}
              caption={item.caption}
              onFileAccepted={item.onFileAccepted}
              onFileRejected={item.onFileRejected}
              onCaptionChange={item.onCaptionChange}
              onClear={item.onClear}
              window={null}
              busy={busy || skipChecked}
              canSend={canSend}
              showCaption={item.showCaption}
              variant="compact"
              labels={{
                dropHint: t("proof.dropHint"),
                dropFormats: t("proof.dropFormats", { mb: MAX_MB }),
                removeAria: t("proof.removeAria"),
              }}
            />
          </div>
        ))}
      </div>

      {!hideActions && (
        <label className="flex items-center gap-2 text-xs text-foreground">
          <input
            type="checkbox"
            checked={skipChecked}
            disabled={locked}
            onChange={(e) => onSkipChange(e.target.checked)}
          />
          {t("withoutScreenshot")}
        </label>
      )}

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

      {!hideActions && (
        <ConfirmCancelButtons
          onCancel={onCancel}
          onConfirm={onSubmit}
          cancelLabel={tCommon("cancel")}
          confirmLabel={submitLabel}
          pending={busy}
          confirmDisabled={!canSend || !canSubmit}
        >
          {onNotifyChange && <NotifyToggle notify={notify} onChange={onNotifyChange} disabled={locked} />}
        </ConfirmCancelButtons>
      )}

    </div>
  );
}
