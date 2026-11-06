"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import { toast } from "sonner";
import { CreditCard, Loader2, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { EmptyState } from "@/components/ui/empty-state";
import { Label } from "@/components/ui/label";
import { PageHeader, PageShell } from "@/components/layout/page-header";
import { CardDialog, type CardFormValue } from "@/components/inventario-cup/card-dialog";
import { BalanceDialog, type BalanceFormValue } from "@/components/inventario-cup/balance-dialog";
import { CardPicker } from "@/components/inventario-cup/card-picker";
import { CardRow, type GydRates } from "@/components/inventario-cup/card-row";
import { FilterChips, TotalsStrip } from "@/components/inventario-cup/inventory-summary";
import { LotDialog, type LotFormValue } from "@/components/inventario-cup/lot-dialog";
import { DeleteLotDialog } from "@/components/inventario-cup/delete-lot-dialog";
import { ServiceCardDialog, type ServiceCardFormValue } from "@/components/inventario-cup/service-card-dialog";
import { UsdBalanceDialog, type UsdBalanceFormValue } from "@/components/inventario-cup/usd-balance-dialog";
import { UsdLotDialog, type UsdLotFormValue } from "@/components/inventario-cup/usd-lot-dialog";
import { useAuth } from "@/hooks/use-auth";
import { useCan } from "@/hooks/use-can";
import { moveCardPriorities } from "@/lib/cup-inventory/format";
import type { InventoryReport } from "@/lib/cup-inventory/read-model";
import type { UsdReport } from "@/lib/usd-inventory/read-model";
import { filterCards, serviceTotals, unifyCards, type CardFilter, type CardService, type UnifiedCard, type UnifiedLot } from "@/lib/card-inventory/unify";

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

const ROUTES: Record<CardService, string> = {
  CUP: "/api/inventario-cup",
  CLASICA: "/api/inventario-usd",
  TROPICAL: "/api/inventario-usd",
};

const EMPTY_USD: UsdReport = {
  cubaMonth: null,
  cards: [],
  totals: {
    CLASICA: { cards: 0, balanceUsd: 0, monthlyLimitUsd: 0, usedThisMonthUsd: 0, remainingMonthUsd: 0 },
    TROPICAL: { cards: 0, balanceUsd: 0, monthlyLimitUsd: 0, usedThisMonthUsd: 0, remainingMonthUsd: 0 },
  },
};

// Admin-only card inventory: the CUP sending cards (daily limit) and the Clásica / Tropical USD cards (monthly limit) in one
// list. One compact row per card; opening it shows the lots (FIFO), the balance figures and the movements. Everything is
// written through the admin RPCs (migrations 239 and 355); this page never computes money, it shows it.
export default function InventarioCupPage() {
  const t = useTranslations("CupInventory");
  const { profileLoading } = useAuth();
  const allowed = useCan("manage-cup-inventory");

  const [cup, setCup] = useState<InventoryReport>({ cubaDay: null, cards: [] });
  const [usd, setUsd] = useState<UsdReport>(EMPTY_USD);
  const [usdFailed, setUsdFailed] = useState(false);
  const [rates, setRates] = useState<GydRates | null>(null);
  const [state, setState] = useState<LoadState>("loading");
  const [showInactive, setShowInactive] = useState(false);
  const [filter, setFilter] = useState<CardFilter>("all");
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  const [cardDialog, setCardDialog] = useState<{ card: UnifiedCard | null } | null>(null);
  const [lotDialog, setLotDialog] = useState<{ cardKey: string; lot: UnifiedLot | null; picking: boolean } | null>(null);
  const [balanceDialog, setBalanceDialog] = useState<{ card: UnifiedCard } | null>(null);
  const [deletingLot, setDeletingLot] = useState<{ card: UnifiedCard; lot: UnifiedLot } | null>(null);

  const load = useCallback(async () => {
    const query = showInactive ? "?includeInactive=1" : "";
    // The CUP report is the page; the USD report and the rates are best effort so a problem there never hides the CUP cards.
    const [cupResult, usdResult, ratesResult] = await Promise.allSettled([
      fetch(`/api/inventario-cup${query}`, { cache: "no-store" }),
      fetch(`/api/inventario-usd${query}`, { cache: "no-store" }),
      fetch("/api/calculator/rates", { cache: "no-store" }),
    ]);

    try {
      if (cupResult.status !== "fulfilled" || !cupResult.value.ok) throw new Error("cup report failed");
      setCup((await cupResult.value.json()) as InventoryReport);
      setState("ok");
    } catch (err) {
      console.error("[inventario-cup]", err);
      setState("error");
      return;
    }

    try {
      if (usdResult.status !== "fulfilled" || !usdResult.value.ok) throw new Error("usd report failed");
      const body = (await usdResult.value.json()) as Partial<UsdReport>;
      setUsd({ ...EMPTY_USD, ...body, cards: body.cards ?? [] });
      setUsdFailed(false);
    } catch (err) {
      console.error("[inventario-usd]", err);
      setUsd(EMPTY_USD);
      setUsdFailed(true);
    }

    try {
      if (ratesResult.status !== "fulfilled" || !ratesResult.value.ok) throw new Error("rates failed");
      const body = (await ratesResult.value.json()) as { rates?: { usdtBuyGyd?: number | null; usdtSellGyd?: number | null } | null };
      setRates(body.rates ? { buy: body.rates.usdtBuyGyd ?? null, sell: body.rates.usdtSellGyd ?? null } : null);
    } catch {
      setRates(null);
    }
  }, [showInactive]);

  useEffect(() => {
    if (!allowed) return;
    void load();
  }, [allowed, load]);

  const cards = useMemo(() => unifyCards(cup.cards, usd.cards), [cup.cards, usd.cards]);
  const visible = useMemo(() => filterCards(cards, filter), [cards, filter]);
  const totals = useMemo(() => serviceTotals(cards), [cards]);
  const activeCards = cards.filter((card) => card.active);

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

  const fail = (failure: string) => (failure === "network" ? t("errors.saveError") : failure);

  function toggle(key: string) {
    setExpanded((current) => {
      const next = new Set(current);
      if (!next.delete(key)) next.add(key);
      return next;
    });
  }

  async function saveNewCard(value: ServiceCardFormValue): Promise<string | null> {
    const last4 = value.last4 === "" ? {} : { last4: value.last4 };
    const failure = value.service === "CUP"
      ? await send("/api/inventario-cup/cards", "POST", { name: value.name, ...last4, dailyLimitCup: value.limit })
      : await send("/api/inventario-usd/cards", "POST", { service: value.service, name: value.name, ...last4, monthlyLimitUsd: value.limit });
    return finishCardSave(failure);
  }

  async function saveUsdCard(card: UnifiedCard, value: ServiceCardFormValue): Promise<string | null> {
    const failure = await send(`/api/inventario-usd/cards/${card.id}`, "PATCH", {
      name: value.name,
      last4: value.last4 === "" ? null : value.last4,
      monthlyLimitUsd: value.limit,
      active: value.active,
    });
    return finishCardSave(failure);
  }

  async function saveCupCard(card: UnifiedCard, value: CardFormValue): Promise<string | null> {
    const failure = await send(`/api/inventario-cup/cards/${card.id}`, "PATCH", {
      name: value.name,
      last4: value.last4 === "" ? null : value.last4,
      dailyLimitCup: value.dailyLimitCup,
      active: value.active,
    });
    return finishCardSave(failure);
  }

  async function finishCardSave(failure: string | null): Promise<string | null> {
    if (failure) return fail(failure);
    toast.success(t("toasts.cardSaved"));
    setCardDialog(null);
    await load();
    return null;
  }

  async function saveLot(card: UnifiedCard, lot: UnifiedLot | null, value: LotFormValue | UsdLotFormValue): Promise<string | null> {
    const base = ROUTES[card.service];
    const failure = lot
      ? await send(`${base}/lots/${lot.id}`, "PATCH", { ...value, note: value.note ?? null })
      : await send(`${base}/lots`, "POST", { cardId: card.id, ...value });
    if (failure) return fail(failure);
    toast.success(t("toasts.lotSaved"));
    setLotDialog(null);
    await load();
    return null;
  }

  async function saveBalance(card: UnifiedCard, value: BalanceFormValue | UsdBalanceFormValue): Promise<string | null> {
    const failure = await send(`${ROUTES[card.service]}/cards/${card.id}/balance`, "POST", value);
    if (failure) return fail(failure);
    toast.success(t("toasts.balanceAdjusted"));
    setBalanceDialog(null);
    await load();
    return null;
  }

  async function deleteLot(card: UnifiedCard, lot: UnifiedLot) {
    const failure = await send(`${ROUTES[card.service]}/lots/${lot.id}`, "DELETE");
    if (failure) {
      toast.error(fail(failure));
    } else {
      toast.success(t("toasts.lotDeleted"));
    }
    setDeletingLot(null);
    await load();
  }

  /** Priorities are per service: the order of Clásica never mixes with CUP or Tropical. */
  async function moveCard(card: UnifiedCard, direction: "up" | "down") {
    const sameService = cards.filter((other) => other.service === card.service);
    for (const patch of moveCardPriorities(sameService, card.id, direction)) {
      const failure = await send(`${ROUTES[card.service]}/cards/${patch.id}`, "PATCH", { priority: patch.priority });
      if (failure) {
        toast.error(fail(failure));
        break;
      }
    }
    await load();
  }

  const lotCard = lotDialog ? cards.find((card) => card.key === lotDialog.cardKey) ?? null : null;
  const lotPicker = lotDialog?.picking && lotCard ? (
    <CardPicker cards={activeCards} value={lotCard.key} onChange={(key) => setLotDialog((current) => (current ? { ...current, cardKey: key } : current))} />
  ) : undefined;
  const editingCup = cardDialog?.card?.service === "CUP" ? cup.cards.find((card) => card.id === cardDialog.card?.id) ?? null : null;
  const editingCupLot = lotCard?.service === "CUP" && lotDialog?.lot ? cup.cards.flatMap((card) => card.lots).find((lot) => lot.id === lotDialog.lot?.id) ?? null : null;
  const cardsOfService = (service: CardService) => cards.filter((card) => card.service === service);

  return (
    <PageShell>
      <PageHeader
        title={t("title")}
        description={t("description")}
        icon={CreditCard}
        actions={
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => setCardDialog({ card: null })}>
              {t("newCard")}
            </Button>
            <Button
              disabled={activeCards.length === 0}
              title={activeCards.length === 0 ? t("picker.none") : undefined}
              onClick={() => activeCards[0] && setLotDialog({ cardKey: activeCards[0].key, lot: null, picking: true })}
            >
              <Plus className="size-4" aria-hidden="true" />
              {t("buyBalance")}
            </Button>
          </div>
        }
      />

      <div className="flex flex-wrap items-center justify-between gap-3 text-sm">
        <p className="text-muted-foreground">
          {cup.cubaDay ? <span className="text-foreground font-medium">{t("cubaDay", { date: dayLabel(cup.cubaDay) })}</span> : null}{" "}
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
      ) : (
        <>
          {usdFailed ? (
            <p role="alert" className="text-sm text-amber-700 dark:text-amber-300">
              {t("usdUnavailable")}
            </p>
          ) : null}
          <TotalsStrip totals={totals} />
          <FilterChips value={filter} onChange={setFilter} />
          {cards.length === 0 ? (
            <EmptyState icon={CreditCard} title={t("empty")} description={t("emptyHint")} />
          ) : (
            <div className="flex flex-col gap-3">
              {visible.map((card) => {
                const group = cardsOfService(card.service);
                return (
                  <CardRow
                    key={card.key}
                    card={card}
                    expanded={expanded.has(card.key)}
                    onToggle={() => toggle(card.key)}
                    rates={rates}
                    isFirst={group[0]?.id === card.id}
                    isLast={group[group.length - 1]?.id === card.id}
                    onMove={(direction) => void moveCard(card, direction)}
                    onEdit={() => setCardDialog({ card })}
                    onLoadLot={() => setLotDialog({ cardKey: card.key, lot: null, picking: false })}
                    onAdjustBalance={() => setBalanceDialog({ card })}
                    onEditLot={(lot) => setLotDialog({ cardKey: card.key, lot, picking: false })}
                    onDeleteLot={(lot) => setDeletingLot({ card, lot })}
                  />
                );
              })}
            </div>
          )}
        </>
      )}

      <CardDialog
        open={editingCup !== null}
        card={editingCup}
        onClose={() => setCardDialog(null)}
        onSave={(value) => (cardDialog?.card ? saveCupCard(cardDialog.card, value) : Promise.resolve(null))}
      />
      <ServiceCardDialog
        open={cardDialog !== null && cardDialog.card?.service !== "CUP"}
        card={cardDialog?.card ?? null}
        onClose={() => setCardDialog(null)}
        onSave={(value) => (cardDialog?.card ? saveUsdCard(cardDialog.card, value) : saveNewCard(value))}
      />
      <BalanceDialog
        open={balanceDialog?.card.service === "CUP"}
        cardName={balanceDialog?.card.name ?? ""}
        currentBalanceCup={balanceDialog?.card.balance ?? 0}
        onClose={() => setBalanceDialog(null)}
        onSave={(value) => (balanceDialog ? saveBalance(balanceDialog.card, value) : Promise.resolve(null))}
      />
      <UsdBalanceDialog
        open={balanceDialog !== null && balanceDialog.card.service !== "CUP"}
        cardName={balanceDialog?.card.name ?? ""}
        currentBalanceUsd={balanceDialog?.card.balance ?? 0}
        onClose={() => setBalanceDialog(null)}
        onSave={(value) => (balanceDialog ? saveBalance(balanceDialog.card, value) : Promise.resolve(null))}
      />
      <DeleteLotDialog
        open={deletingLot !== null}
        cardName={deletingLot?.card.name ?? ""}
        onClose={() => setDeletingLot(null)}
        onConfirm={() => (deletingLot ? deleteLot(deletingLot.card, deletingLot.lot) : Promise.resolve())}
      />
      <LotDialog
        open={lotDialog !== null && lotCard?.service === "CUP"}
        cardName={lotCard?.name ?? ""}
        lot={editingCupLot}
        picker={lotPicker}
        onClose={() => setLotDialog(null)}
        onSave={(value) => (lotDialog && lotCard ? saveLot(lotCard, lotDialog.lot, value) : Promise.resolve(null))}
      />
      <UsdLotDialog
        open={lotDialog !== null && lotCard !== null && lotCard.service !== "CUP"}
        cardName={lotCard?.name ?? ""}
        lot={lotDialog?.lot ?? null}
        picker={lotPicker}
        onClose={() => setLotDialog(null)}
        onSave={(value) => (lotDialog && lotCard ? saveLot(lotCard, lotDialog.lot, value) : Promise.resolve(null))}
      />
    </PageShell>
  );
}
