"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";
import { CreditCard, Loader2, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { EmptyState } from "@/components/ui/empty-state";
import { Label } from "@/components/ui/label";
import { PageHeader, PageShell } from "@/components/layout/page-header";
import { CardDialog, type CardFormValue } from "@/components/inventario-cup/card-dialog";
import { CardPanel } from "@/components/inventario-cup/card-panel";
import { LotDialog, type LotFormValue } from "@/components/inventario-cup/lot-dialog";
import { DeleteLotDialog } from "@/components/inventario-cup/delete-lot-dialog";
import { useAuth } from "@/hooks/use-auth";
import { useCan } from "@/hooks/use-can";
import { moveCardPriorities } from "@/lib/cup-inventory/format";
import type { InventoryCard, InventoryLot, InventoryReport } from "@/lib/cup-inventory/read-model";

type LoadState = "loading" | "ok" | "error";

/** "2026-10-14" -> "14/10/2026". */
function dayLabel(day: string | null): string {
  if (!day) return "";
  const [year, month, date] = day.split("-");
  return `${date}/${month}/${year}`;
}

async function send(url: string, method: string, body?: unknown): Promise<string | null> {
  try {
    const response = await fetch(url, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (response.ok) return null;
    const payload = (await response.json().catch(() => null)) as { error?: string } | null;
    return payload?.error ?? `HTTP ${response.status}`;
  } catch {
    return "network";
  }
}

// Admin-only CUP inventory: sending cards in priority order, the FIFO lots loaded on each, and the daily limit left for the
// current Cuba day. Everything is written through the admin RPCs (migration 239); this page never computes money, it shows it.
export default function InventarioCupPage() {
  const t = useTranslations("CupInventory");
  const { profileLoading } = useAuth();
  const allowed = useCan("manage-cup-inventory");

  const [report, setReport] = useState<InventoryReport>({ cubaDay: null, cards: [] });
  const [state, setState] = useState<LoadState>("loading");
  const [showInactive, setShowInactive] = useState(false);
  const [cardDialog, setCardDialog] = useState<{ card: InventoryCard | null } | null>(null);
  const [lotDialog, setLotDialog] = useState<{ card: InventoryCard; lot: InventoryLot | null } | null>(null);
  const [deletingLot, setDeletingLot] = useState<{ card: InventoryCard; lot: InventoryLot } | null>(null);

  const load = useCallback(async () => {
    try {
      const response = await fetch(`/api/inventario-cup${showInactive ? "?includeInactive=1" : ""}`, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      setReport((await response.json()) as InventoryReport);
      setState("ok");
    } catch (err) {
      console.error("[inventario-cup]", err);
      setState("error");
    }
  }, [showInactive]);

  useEffect(() => {
    if (!allowed) return;
    void load();
  }, [allowed, load]);

  if (profileLoading) {
    return (
      <PageShell>
        <PageHeader title={t("title")} />
      </PageShell>
    );
  }

  if (!allowed) {
    return (
      <PageShell>
        <PageHeader title={t("title")} />
        <p role="alert" className="text-muted-foreground text-sm">
          {t("forbidden")}
        </p>
      </PageShell>
    );
  }

  async function saveCard(card: InventoryCard | null, value: CardFormValue): Promise<string | null> {
    const failure = card
      ? await send(`/api/inventario-cup/cards/${card.id}`, "PATCH", {
          name: value.name,
          last4: value.last4 === "" ? null : value.last4,
          dailyLimitCup: value.dailyLimitCup,
          active: value.active,
        })
      : await send("/api/inventario-cup/cards", "POST", {
          name: value.name,
          ...(value.last4 === "" ? {} : { last4: value.last4 }),
          dailyLimitCup: value.dailyLimitCup,
        });
    if (failure) return failure === "network" ? t("errors.saveError") : failure;
    toast.success(t("toasts.cardSaved"));
    setCardDialog(null);
    await load();
    return null;
  }

  async function saveLot(card: InventoryCard, lot: InventoryLot | null, value: LotFormValue): Promise<string | null> {
    const failure = lot
      ? await send(`/api/inventario-cup/lots/${lot.id}`, "PATCH", { ...value, note: value.note ?? null })
      : await send("/api/inventario-cup/lots", "POST", { cardId: card.id, ...value });
    if (failure) return failure === "network" ? t("errors.saveError") : failure;
    toast.success(t("toasts.lotSaved"));
    setLotDialog(null);
    await load();
    return null;
  }

  async function deleteLot(lot: InventoryLot) {
    const failure = await send(`/api/inventario-cup/lots/${lot.id}`, "DELETE");
    if (failure) {
      toast.error(failure === "network" ? t("errors.saveError") : failure);
    } else {
      toast.success(t("toasts.lotDeleted"));
    }
    setDeletingLot(null);
    await load();
  }

  async function moveCard(card: InventoryCard, direction: "up" | "down") {
    for (const patch of moveCardPriorities(report.cards, card.id, direction)) {
      const failure = await send(`/api/inventario-cup/cards/${patch.id}`, "PATCH", { priority: patch.priority });
      if (failure) {
        toast.error(failure === "network" ? t("errors.saveError") : failure);
        break;
      }
    }
    await load();
  }

  return (
    <PageShell>
      <PageHeader
        title={t("title")}
        description={t("description")}
        icon={CreditCard}
        actions={
          <Button onClick={() => setCardDialog({ card: null })}>
            <Plus className="size-4" aria-hidden="true" />
            {t("newCard")}
          </Button>
        }
      />

      <div className="flex flex-wrap items-center justify-between gap-3 text-sm">
        <p className="text-muted-foreground">
          {report.cubaDay ? <span className="text-foreground font-medium">{t("cubaDay", { date: dayLabel(report.cubaDay) })}</span> : null}{" "}
          {t("cubaDayHint")}
        </p>
        <Label>
          <Checkbox checked={showInactive} onCheckedChange={(checked) => setShowInactive(checked === true)} />
          {t("showInactive")}
        </Label>
      </div>

      {state === "loading" ? (
        <p className="text-muted-foreground flex items-center gap-2 text-sm">
          <Loader2 className="size-4 animate-spin" aria-hidden="true" />
          {t("loading")}
        </p>
      ) : state === "error" ? (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {t("loadError")}
        </p>
      ) : report.cards.length === 0 ? (
        <EmptyState icon={CreditCard} title={t("empty")} description={t("emptyHint")} />
      ) : (
        <div className="flex flex-col gap-4">
          {report.cards.map((card, index) => (
            <CardPanel
              key={card.id}
              card={card}
              isFirst={index === 0}
              isLast={index === report.cards.length - 1}
              onMove={(direction) => void moveCard(card, direction)}
              onEdit={() => setCardDialog({ card })}
              onLoadLot={() => setLotDialog({ card, lot: null })}
              onEditLot={(lot) => setLotDialog({ card, lot })}
              onDeleteLot={(lot) => setDeletingLot({ card, lot })}
            />
          ))}
        </div>
      )}

      <CardDialog
        open={cardDialog !== null}
        card={cardDialog?.card ?? null}
        onClose={() => setCardDialog(null)}
        onSave={(value) => saveCard(cardDialog?.card ?? null, value)}
      />
      <DeleteLotDialog
        open={deletingLot !== null}
        cardName={deletingLot?.card.name ?? ""}
        onClose={() => setDeletingLot(null)}
        onConfirm={() => (deletingLot ? deleteLot(deletingLot.lot) : Promise.resolve())}
      />
      <LotDialog
        open={lotDialog !== null}
        cardName={lotDialog?.card.name ?? ""}
        lot={lotDialog?.lot ?? null}
        onClose={() => setLotDialog(null)}
        onSave={(value) => (lotDialog ? saveLot(lotDialog.card, lotDialog.lot, value) : Promise.resolve(null))}
      />
    </PageShell>
  );
}
