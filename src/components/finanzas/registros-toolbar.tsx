"use client";

import { X } from "lucide-react";
import { useTranslations } from "next-intl";
import { NO_FILTERS, type RegistroFilters, type StatusFilter } from "@/lib/finanzas/registros";
import { cn } from "@/lib/utils";

const CHIPS: ReadonlyArray<{ id: StatusFilter; label: "todas" | "completadas" | "pendientes" | "sinTasa" | "aMano" }> = [
  { id: "all", label: "todas" },
  { id: "completed", label: "completadas" },
  { id: "pending", label: "pendientes" },
  { id: "sinTasa", label: "sinTasa" },
  { id: "manual", label: "aMano" },
];

export interface RegistrosToolbarProps {
  filters: RegistroFilters;
  counts: Record<StatusFilter, number>;
  /** Ledger keys of the services in the table, with the name shown for each. */
  services: ReadonlyArray<{ key: string; name: string }>;
  onChange: (filters: RegistroFilters) => void;
}

/** Search, status chips with counts, the service filter and the client filter a click on "Mejores clientes" sets. */
export function RegistrosToolbar({ filters, counts, services, onChange }: RegistrosToolbarProps) {
  const t = useTranslations("Finanzas.semana.registros");
  const set = (patch: Partial<RegistroFilters>) => onChange({ ...filters, ...patch });
  return (
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <input
        type="search"
        aria-label={t("buscar")}
        placeholder={t("buscarPlaceholder")}
        value={filters.query}
        onChange={(event) => set({ query: event.target.value })}
        className="h-11 min-w-0 flex-1 basis-[200px] rounded-lg border border-input bg-card px-3 text-sm outline-none focus:border-ring"
      />
      <div className="flex flex-wrap gap-1.5" role="group" aria-label={t("estados")}>
        {CHIPS.map((chip) => (
          <button
            key={chip.id}
            type="button"
            data-chip={chip.id}
            aria-pressed={filters.status === chip.id}
            onClick={() => set({ status: chip.id })}
            className={cn(
              "min-h-11 rounded-full border border-border px-3 text-[13px] font-semibold",
              filters.status === chip.id ? "border-foreground bg-foreground text-background" : "bg-card text-foreground hover:bg-muted",
            )}
          >
            {t(chip.label)} {counts[chip.id]}
          </button>
        ))}
      </div>
      <select
        aria-label={t("servicio")}
        value={filters.service ?? ""}
        onChange={(event) => set({ service: event.target.value || null })}
        className="h-11 rounded-lg border border-input bg-card px-2 text-sm outline-none focus:border-ring"
      >
        <option value="">{t("todosServicios")}</option>
        {services.map((service) => <option key={service.key} value={service.key}>{service.name}</option>)}
      </select>
      {filters.client && (
        <span className="inline-flex min-h-11 items-center gap-1 rounded-full bg-muted pl-3 pr-1 text-[13px] font-semibold">
          {t("cliente", { name: filters.client })}
          <button type="button" aria-label={t("quitarCliente")} onClick={() => set({ client: null })} className="inline-flex size-9 items-center justify-center rounded-full hover:bg-accent">
            <X size={14} aria-hidden="true" />
          </button>
        </span>
      )}
    </div>
  );
}

export function hasFilters(filters: RegistroFilters): boolean {
  return filters.status !== NO_FILTERS.status || filters.service !== null || filters.client !== null || filters.query.trim() !== "";
}
