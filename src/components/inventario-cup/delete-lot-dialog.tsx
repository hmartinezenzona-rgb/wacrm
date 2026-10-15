"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";

interface DeleteLotDialogProps {
  open: boolean;
  cardName: string;
  onClose: () => void;
  /** Deletes; the dialog stays open with a spinner until it resolves. */
  onConfirm: () => Promise<void>;
}

/** Confirms deleting a lot in the same dialog style as the lot form, instead of a browser prompt. */
export function DeleteLotDialog({ open, cardName, onClose, onConfirm }: DeleteLotDialogProps) {
  const t = useTranslations("CupInventory");
  const [deleting, setDeleting] = useState(false);

  async function confirm() {
    setDeleting(true);
    await onConfirm();
    setDeleting(false);
  }

  return (
    <Dialog open={open} onOpenChange={(next) => (next || deleting ? undefined : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("lots.confirmDeleteTitle", { card: cardName })}</DialogTitle>
          <DialogDescription>{t("lots.confirmDelete")}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose} disabled={deleting}>
            {t("actions.cancel")}
          </Button>
          <Button type="button" variant="destructive" onClick={() => void confirm()} disabled={deleting}>
            {deleting ? <Loader2 className="size-4 animate-spin" aria-hidden="true" /> : null}
            {t("actions.delete")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
