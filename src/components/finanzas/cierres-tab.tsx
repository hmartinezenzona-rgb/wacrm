import { FinancialCloseSection } from "@/components/resumen/financial-close-section";
import { ArchivedWeeks } from "./archived-weeks";

/** The weekly cuts first, then the financial close of any day, week, month or range. */
export function CierresTab() {
  return (
    <div className="space-y-6">
      <ArchivedWeeks />
      <FinancialCloseSection />
    </div>
  );
}
