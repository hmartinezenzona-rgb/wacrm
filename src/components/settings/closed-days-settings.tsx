"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";
import { CalendarOff, Loader2, Trash2 } from "lucide-react";
import { useTranslations } from "next-intl";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { MOTIVO_MAX, type DiaCerrado } from "@/lib/away-mode/validate";
import { cn } from "@/lib/utils";
import { SettingsPanelHead } from "./settings-panel-head";

const ENDPOINT = "/api/dias-cerrados";
const GUYANA_OFFSET_MS = -4 * 3_600_000;

/** Today's calendar date (YYYY-MM-DD) on Guyana's fixed UTC-4 clock. */
function guyanaToday(now: Date = new Date()): string {
  return new Date(now.getTime() + GUYANA_OFFSET_MS).toISOString().slice(0, 10);
}

function sortDias(dias: DiaCerrado[]): DiaCerrado[] {
  return [...dias].sort((a, b) => (a.fecha < b.fecha ? -1 : a.fecha > b.fecha ? 1 : 0));
}

/**
 * Closed days — extra non-working dates on top of Sundays. Admin only:
 * the API enforces it; the settings rail and page hide the section too.
 */
export function ClosedDaysSettings() {
  const t = useTranslations("ClosedDays");
  const [dias, setDias] = useState<DiaCerrado[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fecha, setFecha] = useState("");
  const [motivo, setMotivo] = useState("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch(ENDPOINT);
        const body = (await res.json()) as { dias?: DiaCerrado[]; error?: string };
        if (cancelled) return;
        if (!res.ok) throw new Error(body.error ?? "load failed");
        setDias(sortDias(body.dias ?? []));
      } catch {
        if (!cancelled) setError(t("loadFailed"));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [t]);

  const formatFecha = useCallback(
    (iso: string) => {
      const d = new Date(`${iso}T00:00:00Z`);
      return t("dateFormat", {
        weekday: t(`weekdays.${d.getUTCDay()}`),
        day: d.getUTCDate(),
        month: t(`months.${d.getUTCMonth()}`),
      });
    },
    [t],
  );

  /** PUT the full list; resolves true on success. */
  async function save(next: DiaCerrado[]): Promise<boolean> {
    setSaving(true);
    setError(null);
    try {
      const res = await fetch(ENDPOINT, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ dias: sortDias(next) }),
      });
      const body = (await res.json().catch(() => ({}))) as {
        dias?: DiaCerrado[];
        error?: string;
      };
      if (!res.ok) {
        const message = body.error ?? t("errorGeneric");
        setError(message);
        toast.error(t("failedToast"));
        return false;
      }
      setDias(sortDias(body.dias ?? next));
      toast.success(t("savedToast"));
      return true;
    } catch {
      setError(t("errorGeneric"));
      toast.error(t("failedToast"));
      return false;
    } finally {
      setSaving(false);
    }
  }

  async function handleAdd(e: FormEvent) {
    e.preventDefault();
    const cleanMotivo = motivo.trim();
    if (!fecha || !cleanMotivo) return setError(t("errorMissing"));
    if (fecha < guyanaToday()) return setError(t("errorPast"));
    if (dias.some((d) => d.fecha === fecha)) return setError(t("errorDuplicate"));
    if (await save([...dias, { fecha, motivo: cleanMotivo }])) {
      setFecha("");
      setMotivo("");
    }
  }

  async function handleRemove(target: string) {
    await save(dias.filter((d) => d.fecha !== target));
  }

  const today = guyanaToday();

  return (
    <section className="max-w-2xl animate-in fade-in-50 duration-200">
      <SettingsPanelHead title={t("title")} description={t("description")} />
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-foreground">
            <CalendarOff className="size-4 text-primary" />
            {t("listTitle")}
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-5">
          {loading ? (
            <p className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="size-4 animate-spin" /> {t("loading")}
            </p>
          ) : dias.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t("empty")}</p>
          ) : (
            <ul className="divide-y divide-border rounded-lg border border-border">
              {dias.map((d) => {
                const past = d.fecha < today;
                const label = formatFecha(d.fecha);
                return (
                  <li
                    key={d.fecha}
                    data-past={past ? "true" : undefined}
                    className={cn(
                      "flex items-center gap-3 px-3 py-2.5",
                      past && "opacity-55",
                    )}
                  >
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2 text-sm font-medium text-foreground">
                        {label}
                        {past ? (
                          <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-normal text-muted-foreground">
                            {t("past")}
                          </span>
                        ) : null}
                      </div>
                      <div className="truncate text-xs text-muted-foreground">
                        {t("botSays", { motivo: d.motivo })}
                      </div>
                    </div>
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      aria-label={t("remove", { date: label })}
                      disabled={saving}
                      onClick={() => handleRemove(d.fecha)}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </li>
                );
              })}
            </ul>
          )}

          <form onSubmit={handleAdd} className="space-y-3" noValidate>
            <div className="grid gap-3 sm:grid-cols-[170px_minmax(0,1fr)]">
              <div className="grid gap-1.5">
                <Label htmlFor="closed-day-date" className="text-muted-foreground">
                  {t("dateLabel")}
                </Label>
                <Input
                  id="closed-day-date"
                  type="date"
                  min={today}
                  value={fecha}
                  onChange={(e) => setFecha(e.target.value)}
                />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="closed-day-motivo" className="text-muted-foreground">
                  {t("motivoLabel")}
                </Label>
                <Input
                  id="closed-day-motivo"
                  type="text"
                  maxLength={MOTIVO_MAX}
                  placeholder={t("motivoPlaceholder")}
                  value={motivo}
                  onChange={(e) => setMotivo(e.target.value)}
                />
              </div>
            </div>
            {error ? (
              <p role="alert" className="text-sm text-destructive">
                {error}
              </p>
            ) : null}
            <Button
              type="submit"
              disabled={saving}
              className="bg-primary text-primary-foreground hover:bg-primary/90"
            >
              {saving ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("saving")}
                </>
              ) : (
                t("add")
              )}
            </Button>
          </form>
        </CardContent>
      </Card>
    </section>
  );
}
