"use client";

import type { KeyboardEvent } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { PageHeader, PageShell } from "@/components/layout/page-header";
import { cn } from "@/lib/utils";
import { FINANZAS_TABS, type FinanzasTab } from "@/lib/finanzas/tabs";
import { CierresTab } from "./cierres-tab";
import { OperacionesTab } from "./operaciones-tab";
import { SemanaTab } from "./semana-tab";

const PANEL_ID = "finanzas-panel";
const tabId = (tab: FinanzasTab) => `finanzas-tab-${tab}`;

/**
 * The one Finanzas section: Semana (the weekly calculator), Cierres (archived weeks and financial closes) and
 * Operaciones (period summary and history). The tab lives in the URL (`?tab=`), so a link or a reload lands on it;
 * only the active panel is mounted, so each tab fetches fresh data when it opens.
 */
export function FinanzasView({ tab }: { tab: FinanzasTab }) {
  const t = useTranslations("Finanzas");
  const router = useRouter();

  const select = (next: FinanzasTab) => {
    if (next !== tab) router.replace(`/finanzas?tab=${next}`, { scroll: false });
  };

  // Roving arrows between tabs, as the tab pattern asks; Home and End jump to the ends.
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    const index = FINANZAS_TABS.indexOf(tab);
    const last = FINANZAS_TABS.length - 1;
    const target =
      event.key === "ArrowRight" ? (index + 1) % FINANZAS_TABS.length
      : event.key === "ArrowLeft" ? (index + last) % FINANZAS_TABS.length
      : event.key === "Home" ? 0
      : event.key === "End" ? last
      : null;
    if (target === null) return;
    event.preventDefault();
    select(FINANZAS_TABS[target]!);
    document.getElementById(tabId(FINANZAS_TABS[target]!))?.focus();
  };

  return (
    <PageShell>
      <PageHeader title={t("title")} description={t("description")} />

      <div
        role="tablist"
        aria-label={t("tablistLabel")}
        className="flex w-fit max-w-full overflow-x-auto rounded-lg border border-border p-0.5"
      >
        {FINANZAS_TABS.map((item) => (
          <button
            key={item}
            id={tabId(item)}
            type="button"
            role="tab"
            aria-selected={tab === item}
            aria-controls={PANEL_ID}
            tabIndex={tab === item ? 0 : -1}
            onClick={() => select(item)}
            onKeyDown={onKeyDown}
            className={cn(
              "rounded-md px-4 py-1.5 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
              tab === item
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            {t(`tabs.${item}`)}
          </button>
        ))}
      </div>

      <div id={PANEL_ID} role="tabpanel" aria-labelledby={tabId(tab)} tabIndex={0} className="focus-visible:outline-none">
        {tab === "semana" ? <SemanaTab /> : tab === "cierres" ? <CierresTab /> : <OperacionesTab />}
      </div>
    </PageShell>
  );
}
