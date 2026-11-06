"use client";

import { useTranslations } from "next-intl";
import { ArrowDown, ArrowUp, ChevronDown, Pencil, Plus, Trash2 } from "lucide-react";
import { format } from "date-fns";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { formatCup, formatRate } from "@/lib/cup-inventory/format";
import { costPerUsd, limitPercent, profitPerUsd, type CardService, type UnifiedCard, type UnifiedLot } from "@/lib/card-inventory/unify";
import { discountLabel, formatUsd } from "@/lib/usd-inventory/format";
import { moneyTextClass } from "@/lib/money-tone";
import { cn } from "@/lib/utils";

/** CUP blue, Clásica amber, Tropical teal. */
export const SERVICE_CHIP_CLASS: Record<CardService, string> = {
  CUP: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-200",
  CLASICA: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-200",
  TROPICAL: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-200",
};

const SERVICE_BAR_CLASS: Record<CardService, string> = {
  CUP: "bg-blue-500",
  CLASICA: "bg-amber-500",
  TROPICAL: "bg-teal-500",
};

/** Current USDT rates in GYD, when the calculator has them; the cost column of USD lots needs the buy rate. */
export interface GydRates {
  buy: number | null;
  sell: number | null;
}

interface CardRowProps {
  card: UnifiedCard;
  expanded: boolean;
  onToggle: () => void;
  rates: GydRates | null;
  isFirst: boolean;
  isLast: boolean;
  onMove: (direction: "up" | "down") => void;
  onEdit: () => void;
  onLoadLot: () => void;
  onAdjustBalance: () => void;
  onEditLot: (lot: UnifiedLot) => void;
  onDeleteLot: (lot: UnifiedLot) => void;
}

function Figure({ label, value, valueClassName }: { label: string; value: string; valueClassName?: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-muted-foreground text-xs">{label}</dt>
      <dd className={cn("text-foreground text-base font-semibold tabular-nums", valueClassName)}>{value}</dd>
    </div>
  );
}

function LotActions({ lot, onEdit, onDelete }: { lot: UnifiedLot; onEdit: () => void; onDelete: () => void }) {
  const t = useTranslations("CupInventory");
  if (lot.exhausted) return <span className="text-xs">{t("lots.exhausted")}</span>;
  if (!lot.editable) {
    return (
      <span className="text-muted-foreground text-xs" title={t("lots.consumed")}>
        {t("lots.consumed")}
      </span>
    );
  }
  return (
    <div className="flex justify-end gap-1">
      <Button variant="ghost" size="icon-sm" aria-label={t("lots.edit")} title={t("lots.edit")} onClick={onEdit}>
        <Pencil className="size-3.5" />
      </Button>
      <Button variant="ghost" size="icon-sm" aria-label={t("lots.delete")} title={t("lots.delete")} onClick={onDelete}>
        <Trash2 className="size-3.5" />
      </Button>
    </div>
  );
}

function CostCell({ lot, rates }: { lot: UnifiedLot; rates: GydRates }) {
  const t = useTranslations("CupInventory");
  const cost = costPerUsd(rates.buy, lot.usdPerUsdt);
  const profit = profitPerUsd(rates.sell, cost);
  if (cost === null) return <TableCell className="text-right">–</TableCell>;
  return (
    <TableCell className="text-right tabular-nums">
      {formatUsd(cost)} {t("lotsTable.gyd")}
      {profit !== null ? (
        <span className={cn("block text-xs", profit >= 0 ? moneyTextClass.profit : moneyTextClass.loss)}>
          {profit >= 0 ? t("lotsTable.earns", { amount: formatUsd(profit) }) : t("lotsTable.loses", { amount: formatUsd(Math.abs(profit)) })}
        </span>
      ) : null}
    </TableCell>
  );
}

export function CardRow({ card, expanded, onToggle, rates, isFirst, isLast, onMove, onEdit, onLoadLot, onAdjustBalance, onEditLot, onDeleteLot }: CardRowProps) {
  const t = useTranslations("CupInventory");
  const isUsd = card.unit === "USD";
  const noBalance = card.active && card.balance <= 0;
  const detailId = `card-detail-${card.key.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
  const showCost = isUsd && rates !== null && rates.buy !== null;
  const percent = limitPercent(card);
  const limitText = (isUsd ? t("row.limitMonth", { used: formatCup(card.used), limit: formatCup(card.limit) }) : t("row.limitDay", { used: formatCup(card.used), limit: formatCup(card.limit) }));

  return (
    <section
      data-card-key={card.key}
      className={cn("bg-card rounded-xl border", noBalance ? "border-red-300 bg-red-50 dark:border-red-500/50 dark:bg-red-950/20" : "border-border")}
    >
      <button
        type="button"
        aria-expanded={expanded}
        aria-controls={detailId}
        onClick={onToggle}
        className="flex min-h-11 w-full flex-wrap items-center gap-x-4 gap-y-2 rounded-xl p-3 text-left"
      >
        <span data-service-chip={card.service} className={cn("rounded-full px-2 py-0.5 text-xs font-medium", SERVICE_CHIP_CLASS[card.service])}>
          {t(`services.${card.service}`)}
        </span>
        <span className="flex min-w-0 flex-1 basis-40 items-center gap-2">
          <span className="text-foreground truncate text-base font-semibold">{card.name}</span>
          {card.last4 ? <span className="text-muted-foreground text-sm tabular-nums">···· {card.last4}</span> : null}
          {card.active ? null : <span className="text-muted-foreground text-xs">{t("row.inactive")}</span>}
        </span>
        <span className={cn("text-base font-semibold tabular-nums", noBalance ? "text-red-600 dark:text-red-400" : moneyTextClass.profit)}>
          {formatCup(card.balance)} <span className="text-muted-foreground text-xs font-normal">{card.unit}</span>
        </span>
        <span className="flex basis-48 flex-col gap-1 text-xs">
          {noBalance ? (
            <span className="font-medium text-red-600 dark:text-red-400">{t("row.noBalance")}</span>
          ) : (
            <>
              <span className="text-muted-foreground tabular-nums">{limitText}</span>
              <span aria-hidden="true" className="bg-muted block h-1.5 w-full overflow-hidden rounded-full">
                <span className={cn("block h-full rounded-full", SERVICE_BAR_CLASS[card.service])} style={{ width: `${percent}%` }} />
              </span>
            </>
          )}
        </span>
        <ChevronDown className={cn("text-muted-foreground size-4 shrink-0 transition-transform", expanded && "rotate-180")} aria-hidden="true" />
      </button>

      {expanded ? (
        <div id={detailId} className="border-border flex flex-col gap-4 border-t p-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <dl className="grid flex-1 grid-cols-2 gap-3 sm:grid-cols-4">
              <Figure label={t("card.balance")} value={formatCup(card.balance)} valueClassName={moneyTextClass.profit} />
              <Figure label={isUsd ? t("cardMonth.monthlyLimit") : t("card.dailyLimit")} value={formatCup(card.limit)} />
              <Figure label={isUsd ? t("cardMonth.usedMonth") : t("card.usedToday")} value={formatCup(card.used)} />
              <Figure label={isUsd ? t("cardMonth.remainingMonth") : t("card.remainingToday")} value={formatCup(card.remaining)} />
            </dl>
            <div className="flex flex-wrap items-center gap-1">
              <Button variant="ghost" size="icon" aria-label={t("card.moveUp")} title={t("card.moveUp")} disabled={isFirst} onClick={() => onMove("up")}>
                <ArrowUp className="size-4" />
              </Button>
              <Button variant="ghost" size="icon" aria-label={t("card.moveDown")} title={t("card.moveDown")} disabled={isLast} onClick={() => onMove("down")}>
                <ArrowDown className="size-4" />
              </Button>
              <Button variant="ghost" size="icon" aria-label={t("card.edit")} title={t("card.edit")} onClick={onEdit}>
                <Pencil className="size-4" />
              </Button>
              <Button variant="outline" size="sm" onClick={onAdjustBalance}>
                {t("card.adjustBalance")}
              </Button>
              <Button variant="outline" size="sm" onClick={onLoadLot} disabled={!card.active}>
                <Plus className="size-4" aria-hidden="true" />
                {t("card.loadLot")}
              </Button>
            </div>
          </div>

          <div className="flex flex-col gap-2">
            <h3 className="text-muted-foreground text-xs font-medium">{t("lots.title")}</h3>
            {card.lots.length === 0 ? (
              <p className="text-muted-foreground text-sm">{t("lots.empty")}</p>
            ) : (
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t("lotsTable.date")}</TableHead>
                      <TableHead className="text-right">{t("lotsTable.bought")}</TableHead>
                      <TableHead className="text-right">{t("lotsTable.paid")}</TableHead>
                      <TableHead className="text-right">{isUsd ? t("lotsTable.discount") : t("lotsTable.rate")}</TableHead>
                      <TableHead className="text-right">{t("lotsTable.left")}</TableHead>
                      {showCost ? <TableHead className="text-right">{t("lotsTable.costPerUsd")}</TableHead> : null}
                      <TableHead>{t("lots.note")}</TableHead>
                      <TableHead />
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {card.lots.map((lot) => (
                      <TableRow key={lot.id} className={lot.exhausted ? "text-muted-foreground" : undefined}>
                        <TableCell className="tabular-nums">{format(new Date(lot.loadedAt), "dd/MM/yyyy")}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatCup(lot.amount)}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatUsd(lot.usdtPaid)}</TableCell>
                        <TableCell className="text-right tabular-nums">
                          {isUsd ? discountLabel(lot.usdPerUsdt ?? 1) : formatRate(lot.rateCupPerUsdt ?? 0)}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">{formatCup(lot.remaining)}</TableCell>
                        {showCost && rates ? <CostCell lot={lot} rates={rates} /> : null}
                        <TableCell className="text-muted-foreground max-w-48 truncate">{lot.note}</TableCell>
                        <TableCell className="text-right">
                          <LotActions lot={lot} onEdit={() => onEditLot(lot)} onDelete={() => onDeleteLot(lot)} />
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
            {isUsd ? <p className="text-muted-foreground text-xs">{t("lotsTable.footnote")}</p> : null}
          </div>

          <div className="flex flex-col gap-2">
            <h3 className="text-muted-foreground text-xs font-medium">{isUsd ? t("movementsMonth.title") : t("movements.title")}</h3>
            {card.movements.length === 0 ? (
              <p className="text-muted-foreground text-sm">{isUsd ? t("movementsMonth.empty") : t("movements.empty")}</p>
            ) : (
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t("movements.time")}</TableHead>
                      <TableHead className="text-right">{t("movements.amount")}</TableHead>
                      <TableHead className="text-right">{t("movements.rate")}</TableHead>
                      <TableHead>{t("movements.destination")}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {card.movements.map((move) => (
                      <TableRow key={move.id}>
                        <TableCell className="tabular-nums">{format(new Date(move.consumedAt), isUsd ? "dd/MM HH:mm" : "HH:mm")}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatCup(move.amount)}</TableCell>
                        <TableCell className="text-right tabular-nums">{isUsd ? discountLabel(move.lotRate) : formatRate(move.lotRate)}</TableCell>
                        <TableCell className="max-w-56 truncate">
                          <span className="text-muted-foreground text-xs">
                            {move.kind === "ajuste"
                              ? t("movements.adjustment")
                              : move.source === "manual" || move.kind === "manual"
                                ? t("movements.manual")
                                : t("movements.operation")}
                          </span>{" "}
                          {move.kind === "ajuste" ? move.reason : move.customerName}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </div>
        </div>
      ) : null}
    </section>
  );
}
