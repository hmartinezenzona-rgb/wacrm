import { CierresOverview } from "./cierres-overview";

/**
 * `active` is false while the tab is hidden but kept mounted. The closed weeks overview first (it ends with the
 * collapsible financial close of any day, week, month or range).
 */
export function CierresTab({ active = true }: { active?: boolean }) {
  return <CierresOverview active={active} />;
}
