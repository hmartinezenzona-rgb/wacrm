"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useAuth } from "@/hooks/use-auth";
import {
  defaultHoraInput,
  describeReturn,
  presetHastaHora,
  presetRato,
  presetRestoDelDia,
  type ReturnDescription,
} from "@/lib/away-mode/presets";
import { canEditSettings, canManageMembers } from "@/lib/auth/roles";
import { cn } from "@/lib/utils";
import { useAwayMode } from "@/components/layout/away-mode-provider";

type Preset = "rato" | "hora" | "resto";

const MOTIVO_MAX = 120;
const CHIPS = ["salir", "diligencia", "festivo", "aniversario"] as const;
const MIN_LEAD_MS = 60_000; // the API wants hasta > now + 1 min

type Translate = ReturnType<typeof useTranslations>;

function whenText(t: Translate, d: ReturnDescription): string {
  const weekday = t(`weekdays.${d.weekday}`);
  return d.day === "today"
    ? t("when.today", { time: d.time })
    : d.day === "tomorrow"
      ? t("when.tomorrow", { time: d.time })
      : t("when.other", { weekday, time: d.time });
}

function resolveHasta(preset: Preset, hora: string, now: Date): Date | null {
  if (preset === "rato") return presetRato(now);
  if (preset === "resto") return presetRestoDelDia(now);
  return presetHastaHora(now, hora);
}

function AwayForm({ onDone }: { onDone: () => void }) {
  const t = useTranslations("AwayMode");
  const { ausencia, set, clear } = useAwayMode();
  const [preset, setPreset] = useState<Preset>("rato");
  const [hora, setHora] = useState(() => defaultHoraInput(new Date()));
  const [motivo, setMotivo] = useState(() => ausencia?.motivo ?? t("popover.defaultMotivo"));
  const [saving, setSaving] = useState(false);

  const now = new Date();
  const hasta = resolveHasta(preset, hora, now);
  const cleanMotivo = motivo.trim();
  const valid =
    hasta !== null &&
    hasta.getTime() > now.getTime() + MIN_LEAD_MS &&
    cleanMotivo.length > 0 &&
    cleanMotivo.length <= MOTIVO_MAX;

  const run = async (action: () => Promise<boolean>) => {
    setSaving(true);
    const ok = await action();
    setSaving(false);
    if (ok) onDone();
  };

  const presets: { id: Preset; label: string; sub: string }[] = [
    { id: "rato", label: t("popover.presetRato"), sub: t("popover.presetRatoSub") },
    { id: "hora", label: t("popover.presetHora"), sub: t("popover.presetHoraSub") },
    { id: "resto", label: t("popover.presetResto"), sub: t("popover.presetRestoSub") },
  ];

  return (
    <div className="flex flex-col gap-3 p-1">
      <div className="flex flex-col gap-0.5">
        <p className="font-heading text-base font-semibold">{t("popover.title")}</p>
        <p className="text-xs text-muted-foreground">{t("popover.subtitle")}</p>
      </div>

      <div className="flex flex-col gap-1.5">
        <span className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
          {t("popover.untilLabel")}
        </span>
        <div className="grid grid-cols-2 gap-1.5">
          {presets.map((p) => (
            <button
              key={p.id}
              type="button"
              aria-pressed={preset === p.id}
              onClick={() => setPreset(p.id)}
              className={cn(
                "flex min-h-12 flex-col items-start justify-center rounded-lg border px-2.5 py-1.5 text-left text-sm transition-colors",
                preset === p.id
                  ? "border-primary bg-primary/10 text-foreground"
                  : "border-border hover:bg-muted",
              )}
            >
              <span className="font-semibold">{p.label}</span>
              <span className="text-[11px] text-muted-foreground">{p.sub}</span>
            </button>
          ))}
        </div>
        {preset === "hora" ? (
          <label className="flex items-center gap-2 text-xs text-muted-foreground">
            {t("popover.timeLabel")}
            <Input
              type="time"
              value={hora}
              onChange={(e) => setHora(e.target.value)}
              className="w-28"
            />
          </label>
        ) : null}
      </div>

      <div className="flex flex-col gap-1.5">
        <label
          htmlFor="away-motivo"
          className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground"
        >
          {t("popover.motivoLabel")}
        </label>
        <Input
          id="away-motivo"
          type="text"
          value={motivo}
          maxLength={MOTIVO_MAX}
          onChange={(e) => setMotivo(e.target.value)}
        />
        <div className="flex flex-wrap gap-1.5">
          {CHIPS.map((chip) => (
            <button
              key={chip}
              type="button"
              onClick={() => setMotivo(`${t("popover.motivoPrefix")} ${t(`popover.chips.${chip}`)}`)}
              className="rounded-full border border-border px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            >
              {t(`popover.chips.${chip}`)}
            </button>
          ))}
        </div>
      </div>

      <div className="flex flex-col gap-1 rounded-lg bg-muted p-2.5">
        <span className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
          {t("popover.previewTitle")}
        </span>
        <p className="text-sm leading-snug">
          {hasta
            ? t("popover.previewSentence", {
                motivo: cleanMotivo,
                when: whenText(t, describeReturn(hasta, now)),
              })
            : "—"}
        </p>
      </div>

      <div className="flex items-center gap-2">
        <Button variant="outline" size="sm" type="button" onClick={onDone}>
          {t("popover.cancel")}
        </Button>
        {ausencia ? (
          <Button
            variant="ghost"
            size="sm"
            type="button"
            disabled={saving}
            onClick={() => void run(clear)}
          >
            {t("popover.returned")}
          </Button>
        ) : null}
        <Button
          size="sm"
          type="button"
          className="ml-auto"
          disabled={saving || !valid}
          onClick={() => hasta && void run(() => set(hasta, cleanMotivo))}
        >
          {saving ? <Loader2 className="size-4 animate-spin" /> : null}
          {saving ? t("popover.saving") : ausencia ? t("popover.update") : t("popover.activate")}
        </Button>
      </div>
    </div>
  );
}

/**
 * Header control for away mode. Everyone sees the current state; only
 * owners/admins get the popover to change it (the API enforces the same).
 */
export function AwayModeButton() {
  const t = useTranslations("AwayMode");
  const { accountRole } = useAuth();
  const { ausencia } = useAwayMode();
  const [open, setOpen] = useState(false);

  const isAdmin =
    !!accountRole && (canManageMembers(accountRole) || canEditSettings(accountRole));

  const label = ausencia
    ? (() => {
        const d = describeReturn(new Date(ausencia.hasta), new Date());
        return d.day === "today"
          ? t("button.untilToday", { time: d.time })
          : d.day === "tomorrow"
            ? t("button.untilTomorrow", { time: d.time })
            : t("button.untilOther", { weekday: t(`weekdays.${d.weekday}`), time: d.time });
      })()
    : t("button.available");

  const appearance = cn(
    "inline-flex h-8 items-center gap-2 rounded-lg border px-2.5 text-sm font-medium",
    ausencia
      ? "border-status-attention/40 bg-status-attention-soft text-status-attention"
      : "border-border text-muted-foreground",
  );
  const dot = (
    <span
      aria-hidden
      className={cn("size-2 shrink-0 rounded-full", ausencia ? "bg-status-attention" : "bg-status-success")}
    />
  );
  const text = <span className="hidden whitespace-nowrap sm:inline">{label}</span>;

  if (!isAdmin) {
    return (
      <span className={appearance} title={t("button.adminOnly")} aria-label={label}>
        {dot}
        {text}
      </span>
    );
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        className={cn(appearance, "transition-colors hover:bg-muted/70")}
        aria-label={label}
      >
        {dot}
        {text}
      </PopoverTrigger>
      <PopoverContent align="end" sideOffset={8} className="w-[22rem] max-w-[calc(100vw-2rem)]">
        <AwayForm onDone={() => setOpen(false)} />
      </PopoverContent>
    </Popover>
  );
}
