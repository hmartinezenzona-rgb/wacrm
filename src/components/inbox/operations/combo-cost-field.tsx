"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { Pencil, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmCancelButtons, cancelOnEscape } from "./confirm-cancel-buttons";
import { EDIT_AREA, FieldRow, UnderlineInput } from "./edit-form-fields";
import { setComboCosto } from "@/lib/remittance-operations/commands";
import { formatNumber } from "@/lib/format-number";

/** Same ceiling `crm_set_combo_costo` enforces (exclusive). */
const MAX_COST_GYD = 1e9;

/**
 * Reads a cost the way GYD amounts are typed: "40,000", "40.000" and "40 000" are forty thousand (groups of three
 * after the first separator); otherwise one "," or "." is the decimal mark ("18000,5"). NaN when it is not a number.
 */
export function parseCostInput(typed: string): number {
  const trimmed = typed.trim();
  if (/^\d{1,3}([.,\s]\d{3})+$/.test(trimmed)) return Number(trimmed.replace(/[.,\s]/g, ""));
  if (/^\d+([.,]\d+)?$/.test(trimmed)) return Number(trimmed.replace(",", "."));
  return Number.NaN;
}

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
  // What was just saved, shown at once (the card's refetch brings the same value a moment later).
  const [saved, setSaved] = useState<{ cost: number | null } | null>(null);
  const [editing, setEditing] = useState(false);
  const current = saved ? saved.cost : costGyd;

  async function submit(cost: number | null) {
    setError(null);
    setPending(true);
    const result = await setComboCosto(operationId, cost);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    setSaved({ cost: result.costGyd });
    setValue(result.costGyd === null ? "" : String(result.costGyd));
    setEditing(false);
    if (cost !== null) toast.success(t("comboCost.saved"));
    onSaved();
  }

  if (current !== null && !editing) {
    return (
      <div className="flex items-center gap-1 border-l-2 border-border pl-2">
        <p className="min-w-0 flex-1 text-sm">
          <span className="text-[11px] text-muted-foreground">{t("comboCost.label")}: </span>
          <span className="font-medium">{formatNumber(current)} GYD</span>
        </p>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          aria-label={t("comboCost.change")}
          title={t("comboCost.change")}
          className="text-muted-foreground"
          onClick={() => {
            setValue(String(current));
            setError(null);
            setEditing(true);
          }}
          disabled={pending}
        >
          <Pencil aria-hidden="true" />
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          aria-label={t("comboCost.clear")}
          title={t("comboCost.clear")}
          className="text-muted-foreground hover:text-destructive"
          onClick={() => void submit(null)}
          disabled={pending}
        >
          <Trash2 aria-hidden="true" />
        </Button>
      </div>
    );
  }

  function handleSave(event: FormEvent) {
    event.preventDefault();
    const parsed = parseCostInput(value);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed >= MAX_COST_GYD) {
      setError(t("comboCost.invalid"));
      return;
    }
    void submit(parsed);
  }

  const cancelEdit = current !== null ? () => setEditing(false) : undefined;

  return (
    <form
      onSubmit={handleSave}
      onKeyDown={cancelEdit ? cancelOnEscape(cancelEdit) : undefined}
      className={EDIT_AREA}
    >
      <div className="flex items-center gap-1">
        <div className="min-w-0 flex-1">
          <FieldRow label={t("comboCost.label")} htmlFor={`combo-cost-${operationId}`}>
            <UnderlineInput
              id={`combo-cost-${operationId}`}
              inputMode="decimal"
              value={value}
              onChange={(event) => setValue(event.target.value)}
              disabled={pending}
            />
          </FieldRow>
        </div>
        <ConfirmCancelButtons type="submit" onCancel={cancelEdit} pending={pending} />
      </div>
      {completed && current === null && (
        <p className="text-[11px] text-amber-600 dark:text-amber-400">{t("comboCost.missing")}</p>
      )}
      {error && (
        <p role="alert" className="text-xs text-destructive">
          {error}
        </p>
      )}
    </form>
  );
}
