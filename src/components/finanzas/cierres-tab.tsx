import { FinancialCloseSection } from "@/components/resumen/financial-close-section";
import { ArchivedWeeks } from "./archived-weeks";

/** `active` is false while the tab is hidden but kept mounted. The weekly cuts first, then the financial close of any day, week, month or range. */
export function CierresTab({ active = true }: { active?: boolean }) {
  return (
    <div className="space-y-6">
      <ArchivedWeeks active={active} />
      <FinancialCloseSection />
    </div>
  );
}
