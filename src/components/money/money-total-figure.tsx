import { ArrowDownToLine, ArrowUpFromLine, Minus, TrendingDown, TrendingUp } from "lucide-react";
import { moneyTextClass, signedMoney, totalTone, type MoneyTone, type TotalKind } from "@/lib/money-tone";

const ICON_CLASS = "mr-1 inline size-[0.8em] align-[-0.05em]";

function toneIcon(kind: TotalKind, tone: MoneyTone) {
  if (kind === "in") return <ArrowDownToLine aria-hidden className={ICON_CLASS} />;
  if (kind === "out") return <ArrowUpFromLine aria-hidden className={ICON_CLASS} />;
  if (tone === "profit") return <TrendingUp aria-hidden className={ICON_CLASS} />;
  if (tone === "loss") return <TrendingDown aria-hidden className={ICON_CLASS} />;
  return <Minus aria-hidden className={ICON_CLASS} />;
}

/**
 * The figure of a totals card: icon plus amount in the tone of what it stands for. Only the result carries a sign
 * (+ / −); colour is never the only cue. `format` renders an unsigned magnitude. The card gets its stripe from
 * `moneyStripeClass[totalTone(kind, value)]`.
 */
export function MoneyTotalFigure({
  kind,
  value,
  format,
}: {
  kind: TotalKind;
  value: number;
  format: (magnitude: number) => string;
}) {
  const tone = totalTone(kind, value);
  const text = kind === "result" ? signedMoney(value, format) : format(value);
  return (
    <span data-tone={tone} className={moneyTextClass[tone]}>
      {toneIcon(kind, tone)}
      {text}
    </span>
  );
}
