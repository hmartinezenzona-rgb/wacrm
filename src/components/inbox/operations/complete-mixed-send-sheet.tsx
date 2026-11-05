"use client";

// ============================================================
// "Completar envio": completes every part of a mixed send paid with one deposit from one sheet. It is only a driver:
// each part is the usual `CompleteTransferContainer` (proofs, CUP source card, refusal reasons) and each part is
// delivered through the same deliver route, one after another, never a new completion path. The parts are a snapshot
// taken when the sheet opened, so a refetch that turns a delivered part into history does not move the sheet.
// ============================================================

import { useCallback, useRef, useState, type MutableRefObject } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { CompleteTransferContainer, type CompletePartHandle } from "./complete-transfer-container";
import { NotifyToggle } from "./notify-toggle";

export interface CompleteMixedSendPart {
  id: string;
  /** Service name and amount, as the group card shows them. */
  title: string;
  isZelle: boolean;
  beneficiaries: { id: string; isZelle: boolean }[];
}

export interface CompleteMixedSendSheetProps {
  conversationId: string;
  parts: CompleteMixedSendPart[];
  /** The deposit that pays the whole send, already formatted. */
  depositText: string;
  /** The sheet closed; `anyDone` says whether a part was completed, so the panel should refetch. */
  onClose: (anyDone: boolean) => void;
}

export function CompleteMixedSendSheet({ conversationId, parts, depositText, onClose }: CompleteMixedSendSheetProps) {
  const t = useTranslations("Inbox.operationsPanel.completeMixedSend");
  const tSkip = useTranslations("Inbox.operationsPanel.completeTransfer");
  const [doneIds, setDoneIds] = useState<ReadonlySet<string>>(new Set());
  const [ready, setReady] = useState<Record<string, boolean>>({});
  const [notify, setNotify] = useState(true);
  const [running, setRunning] = useState(false);
  const handles = useRef<Record<string, { current: CompletePartHandle | null }>>({});
  const doneRef = useRef<Set<string>>(new Set());
  const runningRef = useRef(false);

  const handleFor = (id: string) => (handles.current[id] ??= { current: null });
  const remaining = parts.filter((part) => !doneIds.has(part.id));
  const missing = remaining.filter((part) => !ready[part.id]).length;
  const beneficiaryCount = parts.reduce((sum, part) => sum + Math.max(part.beneficiaries.length, 1), 0);

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

  return (
    <Dialog open onOpenChange={(open) => !open && close()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{t("title")}</DialogTitle>
          <DialogDescription>
            {t("subtitle", { parts: parts.length, beneficiaries: beneficiaryCount, amount: depositText })}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          {parts.map((part) => (
            <section key={part.id} className="overflow-hidden rounded-xl border border-border">
              <header className="flex items-center justify-between gap-2 bg-muted/40 px-3 py-2">
                <h4 className="text-sm font-semibold tabular-nums text-foreground">{part.title}</h4>
                {doneIds.has(part.id) && (
                  <span className="rounded-full bg-emerald-500/10 px-2 py-0.5 text-[11px] font-semibold text-emerald-600 dark:text-emerald-400">
                    {t("partDone")}
                  </span>
                )}
              </header>
              {!doneIds.has(part.id) && (
                <div className="p-2">
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
                </div>
              )}
            </section>
          ))}
        </div>

        <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-3">
          <div className="flex items-center gap-1 text-xs text-muted-foreground">
            <NotifyToggle notify={notify} onChange={setNotify} disabled={running} />
            <span>{t("notify")}</span>
          </div>
          {missing > 0 && <span className="text-xs text-amber-600 dark:text-amber-400">{t("missing", { count: missing })}</span>}
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" disabled={running || remaining.length === 0} onClick={() => void completeAll(true)}>
              {tSkip("withoutScreenshot")}
            </Button>
            <Button type="button" disabled={running || remaining.length === 0 || missing > 0} onClick={() => void completeAll(false)}>
              {running ? t("running") : t(doneIds.size > 0 ? "confirmRest" : "confirm", { count: remaining.length })}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
