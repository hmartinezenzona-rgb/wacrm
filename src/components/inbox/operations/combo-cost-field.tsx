"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { setComboCosto } from "@/lib/remittance-operations/commands";

/** Same ceiling `crm_set_combo_costo` enforces (exclusive). */
const MAX_COST_GYD = 1e9;

interface ComboCostFieldProps {
  operationId: string;
  /** The saved cost, `null` until entered. */
  costGyd: number | null;
  /** The combo is completed: it already reached the calculator, so a missing cost is worth flagging. */
  completed: boolean;
  /** Called after a save or clear, so the panel refetches. */
  onSaved: () => void;
}

/**
 * Owner/admin entry of what a combo cost, in GYD (one total per operation). The
 * calculator prices the combo from it, and leaves the line pending until it is set.
 * The card decides who sees this; the API and RPC re-check owner/admin.
 */
export function ComboCostField({ operationId, costGyd, completed, onSaved }: ComboCostFieldProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [value, setValue] = useState(costGyd === null ? "" : String(costGyd));
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(cost: number | null) {
    setError(null);
    setPending(true);
    const result = await setComboCosto(operationId, cost);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    if (cost === null) setValue("");
    onSaved();
  }

  function handleSave(event: FormEvent) {
    event.preventDefault();
    const trimmed = value.trim();
    const parsed = trimmed === "" ? Number.NaN : Number(trimmed);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed >= MAX_COST_GYD) {
      setError(t("comboCost.invalid"));
      return;
    }
    void submit(parsed);
  }

  return (
    <form onSubmit={handleSave} className="space-y-1.5 rounded-md border border-border bg-muted/40 p-2">
      <Label htmlFor={`combo-cost-${operationId}`}>{t("comboCost.label")}</Label>
      <Input
        id={`combo-cost-${operationId}`}
        inputMode="decimal"
        value={value}
        onChange={(event) => setValue(event.target.value)}
        disabled={pending}
      />
      {completed && costGyd === null && (
        <p className="text-xs text-amber-600 dark:text-amber-400">{t("comboCost.missing")}</p>
      )}
      {error && (
        <p role="alert" className="text-xs text-destructive">
          {error}
        </p>
      )}
      <div className="flex justify-end gap-2">
        {costGyd !== null && (
          <Button type="button" variant="ghost" size="sm" onClick={() => void submit(null)} disabled={pending}>
            {t("comboCost.clear")}
          </Button>
        )}
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? t("saving") : t("save")}
        </Button>
      </div>
    </form>
  );
}
