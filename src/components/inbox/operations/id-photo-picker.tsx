"use client";

import { useRef, useState, type KeyboardEvent } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { fetchChatImages } from "@/lib/remittance-operations/commands";
import type { ChatImage } from "@/lib/remittance-operations/types";
import { cn } from "@/lib/utils";

interface IdPhotoPickerProps {
  conversationId: string;
  /** The wamid currently stored (marked as pressed in the grid); null when there is none. */
  selectedWamid: string | null;
  /** Text of the trigger: "Elegir del chat" when there is no photo, "Cambiar" when there is one. */
  label: string;
  disabled?: boolean;
  /** Receives the chosen image's message id (`id_photo_wamid`). */
  onPick: (wamid: string) => void;
}

type LoadState =
  | { kind: "loading" }
  | { kind: "error" }
  | { kind: "ready"; images: ChatImage[] };

function formatTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return new Intl.DateTimeFormat(undefined, { dateStyle: "short", timeStyle: "short" }).format(date);
}

/**
 * "Elegir del chat": a text trigger that opens a compact dialog with the thumbnails of the conversation's images
 * (newest first, as `crm_imagenes_de_conversacion` returns them). The images are fetched when the dialog opens, never
 * before. Choosing one reports its wamid and closes the dialog; the caller decides what to do with it.
 */
export function IdPhotoPicker({ conversationId, selectedWamid, label, disabled = false, onPick }: IdPhotoPickerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [open, setOpen] = useState(false);
  const [state, setState] = useState<LoadState>({ kind: "loading" });
  const requestId = useRef(0);

  async function load() {
    const id = ++requestId.current;
    setState({ kind: "loading" });
    const result = await fetchChatImages(conversationId);
    if (id !== requestId.current) return;
    setState(result.ok ? { kind: "ready", images: result.data } : { kind: "error" });
  }

  function handleOpenChange(next: boolean) {
    setOpen(next);
    if (next) void load();
    else requestId.current++;
  }

  function senderLabel(senderType: string): string {
    if (senderType === "customer") return t("idPhotoFromCustomer");
    if (senderType === "bot") return t("idPhotoFromBot");
    return t("idPhotoFromTeam");
  }

  // The dialog is portaled out of the form that owns the trigger, but React events still bubble through the portal:
  // Enter would save that form and Escape would cancel it. Keys typed here stay here; Escape only closes the dialog.
  function handleKeyDown(event: KeyboardEvent<HTMLElement>) {
    event.stopPropagation();
    if (event.key === "Escape") handleOpenChange(false);
  }

  return (
    <>
      <Button
        type="button"
        variant="link"
        size="xs"
        disabled={disabled}
        onClick={() => handleOpenChange(true)}
        // The edit form around the trigger saves on Enter; on this button Enter / Space must only press it.
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") event.stopPropagation();
        }}
      >
        {label}
      </Button>
      <Dialog open={open} onOpenChange={handleOpenChange}>
        <DialogContent onKeyDown={handleKeyDown} className="max-h-[80vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("idPhotoPickerTitle")}</DialogTitle>
          </DialogHeader>
          {state.kind === "loading" && (
            <div className="flex justify-center py-6 text-muted-foreground" aria-busy="true">
              <Loader2 className="size-4 animate-spin" aria-hidden="true" />
            </div>
          )}
          {state.kind === "error" && (
            <p role="alert" className="text-xs text-destructive">
              {t("idPhotoPickerLoadError")}
            </p>
          )}
          {state.kind === "ready" && state.images.length === 0 && (
            <p className="text-xs text-muted-foreground">{t("idPhotoPickerEmpty")}</p>
          )}
          {state.kind === "ready" && state.images.length > 0 && (
            <ul className="grid grid-cols-3 gap-2">
              {state.images.map((image) => {
                const time = formatTime(image.createdAt);
                const selected = image.wamid === selectedWamid;
                return (
                  <li key={image.id}>
                    <button
                      type="button"
                      data-wamid={image.wamid}
                      aria-pressed={selected}
                      onClick={() => {
                        onPick(image.wamid);
                        handleOpenChange(false);
                      }}
                      className={cn(
                        "block w-full rounded-md text-left outline-none focus-visible:ring-3 focus-visible:ring-ring/50",
                        selected && "ring-2 ring-primary",
                      )}
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element -- chat media lives in a public storage bucket; same <img> the receipts viewer uses */}
                      <img
                        src={image.mediaUrl}
                        alt={t("idPhotoImageAlt", { time })}
                        loading="lazy"
                        className="aspect-square w-full rounded-md bg-muted object-cover"
                      />
                      <span className="mt-0.5 block truncate text-[11px] text-muted-foreground">
                        {senderLabel(image.senderType)} · {time}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
