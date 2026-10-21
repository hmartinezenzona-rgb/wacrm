"use client";

import { useTranslations } from "next-intl";
import { ArrowDown, ArrowUp, Pencil, Plus, Trash2 } from "lucide-react";
import { format } from "date-fns";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { formatCup, formatRate } from "@/lib/cup-inventory/format";
import { moneyTextClass } from "@/lib/money-tone";
import { cn } from "@/lib/utils";
import type { InventoryCard, InventoryLot } from "@/lib/cup-inventory/read-model";

interface CardPanelProps {
  card: InventoryCard;
  isFirst: boolean;
  isLast: boolean;
  onMove: (direction: "up" | "down") => void;
  onEdit: () => void;
  onLoadLot: () => void;
  onAdjustBalance: () => void;
  onEditLot: (lot: InventoryLot) => void;
  onDeleteLot: (lot: InventoryLot) => void;
}

function Figure({ label, value, valueClassName }: { label: string; value: string; valueClassName?: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-muted-foreground text-xs">{label}</dt>
      <dd className={cn("text-foreground text-base font-semibold tabular-nums", valueClassName)}>{value}</dd>
    </div>
  );
}

export function CardPanel({ card, isFirst, isLast, onMove, onEdit, onLoadLot, onAdjustBalance, onEditLot, onDeleteLot }: CardPanelProps) {
  const t = useTranslations("CupInventory");

  return (
    <section className="border-border bg-card flex flex-col gap-4 rounded-xl border p-4" data-card-id={card.id}>
      <header className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <h2 className="text-foreground truncate text-base font-semibold">{card.name}</h2>
          {card.last4 ? <span className="text-muted-foreground text-sm tabular-nums">•••• {card.last4}</span> : null}
          <Badge variant="secondary">{t("card.priority", { n: card.priority })}</Badge>
          {card.active ? null : <Badge variant="outline">{t("card.inactive")}</Badge>}
        </div>
        <div className="flex items-center gap-1">
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
      </header>

      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Figure label={t("card.balance")} value={formatCup(card.balanceCup)} valueClassName={moneyTextClass.profit} />
        <Figure label={t("card.dailyLimit")} value={formatCup(card.dailyLimitCup)} />
        <Figure label={t("card.usedToday")} value={formatCup(card.usedTodayCup)} />
        <Figure label={t("card.remainingToday")} value={formatCup(card.remainingLimitTodayCup)} />
      </dl>

      <div className="flex flex-col gap-2">
        <h3 className="text-muted-foreground text-xs font-medium">{t("lots.title")}</h3>
        {card.lots.length === 0 ? (
          <p className="text-muted-foreground text-sm">{t("lots.empty")}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("lots.loadedAt")}</TableHead>
                <TableHead className="text-right">{t("lots.amount")}</TableHead>
                <TableHead className="text-right">{t("lots.remaining")}</TableHead>
                <TableHead className="text-right">{t("lots.rate")}</TableHead>
                <TableHead>{t("lots.note")}</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {card.lots.map((lot) => (
                <TableRow key={lot.id} className={lot.exhausted ? "text-muted-foreground" : undefined}>
                  <TableCell className="tabular-nums">{format(new Date(lot.loadedAt), "dd/MM/yyyy")}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatCup(lot.amountCup)}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatCup(lot.remainingCup)}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatRate(lot.rateCupPerUsdt)}</TableCell>
                  <TableCell className="text-muted-foreground max-w-48 truncate">{lot.note}</TableCell>
                  <TableCell className="text-right">
                    {lot.exhausted ? (
                      <span className="text-xs">{t("lots.exhausted")}</span>
                    ) : lot.editable ? (
                      <div className="flex justify-end gap-1">
                        <Button variant="ghost" size="icon-sm" aria-label={t("lots.edit")} title={t("lots.edit")} onClick={() => onEditLot(lot)}>
                          <Pencil className="size-3.5" />
                        </Button>
                        <Button variant="ghost" size="icon-sm" aria-label={t("lots.delete")} title={t("lots.delete")} onClick={() => onDeleteLot(lot)}>
                          <Trash2 className="size-3.5" />
                        </Button>
                      </div>
                    ) : (
                      <span className="text-muted-foreground text-xs" title={t("lots.consumed")}>
                        {t("lots.consumed")}
                      </span>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>

      <div className="flex flex-col gap-2">
        <h3 className="text-muted-foreground text-xs font-medium">{t("movements.title")}</h3>
        {card.consumptionsToday.length === 0 ? (
          <p className="text-muted-foreground text-sm">{t("movements.empty")}</p>
        ) : (
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
              {card.consumptionsToday.map((move) => (
                <TableRow key={move.id}>
                  <TableCell className="tabular-nums">{format(new Date(move.consumedAt), "HH:mm")}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatCup(move.amountCup)}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatRate(move.lotRateCupPerUsdt)}</TableCell>
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
        )}
      </div>
    </section>
  );
}
