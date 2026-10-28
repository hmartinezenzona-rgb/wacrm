import { MoneyTotalFigure } from "@/components/money/money-total-figure";
import { formatNumber as formatMoneyNumber } from "@/lib/format-number";
import { moneyStripeClass, totalTone } from "@/lib/money-tone";

/** Display format of a money figure: "1 157 712,40". */
export function formatNumber(value: number): string {
  return formatMoneyNumber(value, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** One of the three totals boxes: accent stripe, icon and figure in the tone of what it stands for. */
export function TotalBox({ title, kind, value }: { title: string; kind: "in" | "out" | "result"; value: number }) {
  return (
    <div className={`legacyTotalBox ${moneyStripeClass[totalTone(kind, value)]}`}>
      <h3>{title}</h3>
      <p style={{ fontSize: "1.5em", fontWeight: "bold", margin: "5px 0" }}><MoneyTotalFigure kind={kind} value={value} format={formatNumber} /></p>
    </div>
  );
}

// The cut is shown on the Guyana business day, like the rest of the CRM's dates.
const CUT_DATE_FORMAT = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Guyana", year: "numeric", month: "2-digit", day: "2-digit" });

export function cutDate(cutAt: string): string {
  const date = new Date(cutAt);
  return Number.isNaN(date.getTime()) ? cutAt.slice(0, 10) : CUT_DATE_FORMAT.format(date);
}
