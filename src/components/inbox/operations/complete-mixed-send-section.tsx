"use client";

// ============================================================
// "Completar envio": completes every part of a mixed send paid with one deposit, INLINE in the mixed block and styled
// like `CompleteTransferSection`. It is only a driver: each part is the usual `CompleteTransferContainer` (proofs, CUP
// source card, refusal reasons) and each part is delivered through the same deliver route, one after another, never a
// new completion path. The parts are a snapshot taken by the panel when the section opened, so a refetch that turns a
// delivered part into history does not move the section.
// ============================================================

import { useCallback, useRef, useState, type MutableRefObject, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { CompleteTransferContainer, type CompletePartHandle } from "./complete-transfer-container";
import { NotifyToggle } from "./notify-toggle";
import { MethodIcon } from "./operation-icons";

export interface CompleteMixedSendPart {
  id: string;
  /** Service name and amount, as the group card shows them. */
  title: string;
  /** The part's service key, for its icon. */
  method: string | null;
  isZelle: boolean;
  beneficiaries: { id: string; isZelle: boolean }[];
}

export interface CompleteMixedSendSectionProps {
  conversationId: string;
  parts: CompleteMixedSendPart[];
  /** The section closed; `anyDone` says whether a part was completed, so the panel should refetch. */
  onClose: (anyDone: boolean) => void;
}

/** Renders the general customer message with its `*bold*` part. */
function CustomerMessage({ text }: { text: string }): ReactNode {
  return text.split(/(\*[^*]+\*)/).map((piece, index) =>
    piece.startsWith("*") && piece.endsWith("*") && piece.length > 2 ? <strong key={index}>{piece.slice(1, -1)}</strong> : piece,
  );
}

export function CompleteMixedSendSection({ conversationId, parts, onClose }: CompleteMixedSendSectionProps) {
  const t = useTranslations("Inbox.operationsPanel.completeMixedSend");
  const tSkip = useTranslations("Inbox.operationsPanel.completeTransfer");
  const tCommon = useTranslations("Inbox.operationsPanel");
  const [doneIds, setDoneIds] = useState<ReadonlySet<string>>(new Set());
  const [ready, setReady] = useState<Record<string, boolean>>({});
  const [notify, setNotify] = useState(true);
  const [skipChecked, setSkipChecked] = useState(false);
  const [running, setRunning] = useState(false);
  const handles = useRef<Record<string, { current: CompletePartHandle | null }>>({});
  const doneRef = useRef<Set<string>>(new Set());
  const runningRef = useRef(false);

  const handleFor = (id: string) => (handles.current[id] ??= { current: null });
  const remaining = parts.filter((part) => !doneIds.has(part.id));
  const missing = remaining.filter((part) => !ready[part.id]).length;

  const markDone = useCallback((id: string) => {
    doneRef.current.add(id);
    setDoneIds(new Set(doneRef.current));
  }, []);

  /** Completes the parts that are not done yet, in order, and stops at the first one that does not deliver: its banner
   *  shows why, and the next click continues from it without touching the parts already completed. */
  async function completeAll(skip: boolean) {
    if (runningRef.current) return;
    runningRef.current = true;
    setRunning(true);
    try {
      for (const part of parts) {
        if (doneRef.current.has(part.id)) continue;
        const handle = handleFor(part.id).current;
        if (!handle) return;
        if (!(await handle.submit(skip))) return;
      }
      onClose(true);
    } finally {
      runningRef.current = false;
      setRunning(false);
    }
  }

  const close = () => {
    if (!runningRef.current) onClose(doneRef.current.size > 0);
  };


  const confirmKey = skipChecked ? (doneIds.size > 0 ? "confirmSkipRest" : "confirmSkip") : doneIds.size > 0 ? "confirmRest" : "confirm";
  const showMissing = !skipChecked && missing > 0;

  return (
    <div
      className="space-y-2 rounded-lg border border-border bg-muted/30 p-3"
      onKeyDown={running ? undefined : cancelOnEscape(close)}
    >
      <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">{t("title")}</p>

      <div className="space-y-2">
        {parts.map((part) => (
          <section key={part.id} className="space-y-1.5 border-t border-border pt-2 first:border-t-0 first:pt-0">
            <header className="flex items-center justify-between gap-2">
              <h5 className="flex items-center gap-1.5 text-[13px] font-semibold tabular-nums text-foreground">
                <MethodIcon method={part.method} label={part.title} />
                {part.title}
              </h5>
              {doneIds.has(part.id) && (
                <span className="rounded-full bg-emerald-500/10 px-2 py-0.5 text-[11px] font-semibold text-emerald-600 dark:text-emerald-400">
                  {t("partDone")}
                </span>
              )}
            </header>
            {!doneIds.has(part.id) && (
              <CompleteTransferContainer
                operationId={part.id}
                conversationId={conversationId}
                isZelle={part.isZelle}
                beneficiaries={part.beneficiaries}
                onDone={() => markDone(part.id)}
                onCancel={() => {}}
                part={{
                  handleRef: handleFor(part.id) as MutableRefObject<CompletePartHandle | null>,
                  notify,
                  onReadyChange: (isReady) => setReady((prev) => (prev[part.id] === isReady ? prev : { ...prev, [part.id]: isReady })),
                }}
              />
            )}
          </section>
        ))}
      </div>

      <label className="flex items-center gap-2 text-xs text-foreground">
        <input type="checkbox" checked={skipChecked} disabled={running || remaining.length === 0} onChange={(e) => setSkipChecked(e.target.checked)} />
        {tSkip("withoutScreenshot")}
      </label>

      {notify && (
        <div className="rounded-md border border-border bg-card px-2 py-1.5 text-xs text-foreground">
          <p className="mb-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">{t("customerMessageTitle")}</p>
          <CustomerMessage text={t("customerMessage")} />
        </div>
      )}

      {showMissing && <p className="text-[11px] text-amber-600 dark:text-amber-400">{t("missing", { count: missing })}</p>}

      <ConfirmCancelButtons
        onCancel={close}
        onConfirm={() => void completeAll(skipChecked)}
        cancelLabel={tCommon("cancel")}
        confirmLabel={t(confirmKey, { count: remaining.length })}
        pending={running}
        confirmDisabled={remaining.length === 0 || (!skipChecked && missing > 0)}
      >
        <NotifyToggle notify={notify} onChange={setNotify} disabled={running} />
      </ConfirmCancelButtons>
    </div>
  );
}
