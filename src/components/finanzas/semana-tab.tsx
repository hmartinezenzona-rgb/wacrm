"use client";

import { Fragment, useEffect, useMemo, useRef, useState, type ChangeEvent, type KeyboardEvent } from "react";
import { Check, Loader2, Pencil, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { isComboCostPending, pendingReason, type CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { guyanaToday, manualEntriesFromText, removeRegisteredLines } from "@/lib/calculator/manual-entries";
import { formatNumber, TotalBox } from "./legacy-calc-format";
import { ServiceDot } from "@/components/service/service-dot";
import { moneyCellProps, profitTone } from "@/lib/money-tone";
import { canEditEntryCost, canEditEntryRates, recomputeInvestment } from "@/lib/calculator/entry-rates";
import { parseManualLineRates, parseManualUnitLine } from "@/lib/calculator/web-calculator";
import { chatEntryAmountExportText, chatEntryAmountText, ledgerServiceLabel } from "@/lib/calculator/entry-display";
import { applyCalculatorEntryRealtimeEvent, insertCalculatorEntry, type ChatCalculatorEntry } from "@/lib/calculator/realtime-entry";
import { useCalculatorEntriesRealtime } from "@/hooks/use-calculator-entries-realtime";
import { num } from "@/lib/finanzas/number-format";
import { rateValueOf, type RateKey } from "@/lib/finanzas/rate-groups";
import { RatesCard } from "./rates-card";
import { SemanaOverview } from "./semana-overview";
import "./calculadora.module.css";

const STORAGE_KEYS = {
  raw: "remesas_rawText",
  period: "remesas_periodo",
} as const;

/** The .txt export keeps its plain figures: the owner pastes it elsewhere. */
function plainNumber(value: number): string {
  return value.toFixed(2);
}

function chatTotals(entries: ChatCalculatorEntry[]) {
  return entries.reduce(
    (totals, entry) => {
      if (entry.status !== "completed") return totals;
      return {
        fact: totals.fact + (entry.facturadoGyd ?? 0),
        inv: totals.inv + (entry.invertidoGyd ?? 0),
        ret: totals.ret + (entry.retornoGyd ?? 0),
      };
    },
    { fact: 0, inv: 0, ret: 0 },
  );
}

function lineStart(value: string, cursor: number): number {
  return value.lastIndexOf("\n", cursor - 1) + 1;
}

function insertBullet(value: string, cursor: number): { value: string; cursor: number } {
  const needsBreak = cursor > 0 && value[cursor - 1] !== "\n";
  const insertion = `${needsBreak ? "\n" : ""}• `;
  return { value: `${value.slice(0, cursor)}${insertion}${value.slice(cursor)}`, cursor: cursor + insertion.length };
}

/** ARQ's USD -> MXN ticker as stored by migration 297 and its health (298); read-only in this card. */
type ArqRateInfo = {
  valor: number | string;
  fuente?: string | null;
  edad_min?: number | string | null;
  ask?: string | null;
  bid?: string | null;
  fecha_arq?: string | null;
  ultimo_arq_at?: string | null;
  ultimo_arq_ok?: boolean | null;
  ultimo_motivo?: string | null;
  fallos_arq_consecutivos?: number | string | null;
};

const ARQ_STALE_MINUTES = 120;

function arqValueOf(info: ArqRateInfo | null): number | null {
  if (!info) return null;
  const value = Number(info.valor);
  return Number.isFinite(value) ? value : null;
}

function arqAskLabel(info: ArqRateInfo): string | null {
  const ask = Number(info.ask);
  return Number.isFinite(ask) ? `ask ${num(ask, 6)}` : null;
}

/** "hace 2 min" / "hace 3 h". */
function arqAgeLabel(minutes: number): string {
  if (minutes < 60) return `hace ${Math.max(0, Math.round(minutes))} min`;
  return `hace ${Math.round(minutes / 60)} h`;
}

/** ARQ's own timestamp, on the Guyana business day like the rest of the CRM. */
function arqTimeLabel(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const utc = /(Z|[+-]\d\d:?\d\d)$/.test(iso) ? iso : `${iso}Z`;
  const date = new Date(utc);
  if (Number.isNaN(date.getTime())) return null;
  return `ARQ ${new Intl.DateTimeFormat("en-GB", {
    timeZone: "America/Guyana", hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(date)}`;
}

/** What the correction routes answer for one entry (the rate snapshot is present on the ledger payload). */
type StoredEntryFigures = Pick<ChatCalculatorEntry, "id" | "facturadoGyd" | "invertidoGyd" | "retornoGyd"> &
  Partial<Pick<ChatCalculatorEntry, "cupGlobalRate" | "cupRate" | "usdtBuyGyd" | "usdtSellGyd" | "costGyd" | "basisGyd" | "saleGyd">> & {
    status: string;
  };

export function SemanaTab() {
  const [rawText, setRawText] = useState("");
  const [periodo, setPeriodo] = useState("");
  const [rates, setRates] = useState<CalculatorRates | null>(null);
  const [arqRate, setArqRate] = useState<ArqRateInfo | null>(null);
  const [selectedRate, setSelectedRate] = useState<RateKey>("cup_global_rate");
  // The rate being edited in place; it closes by itself when a save brings a new rates version (`rates` changes).
  const [editingRate, setEditingRate] = useState<{ key: RateKey; rates: CalculatorRates | null } | null>(null);
  // null = show the selected rate's current value; a string = what the admin typed.
  const [rateDraft, setRateDraft] = useState<string | null>(null);
  const [ratesLocked, setRatesLocked] = useState(false);
  const [ratesSaving, setRatesSaving] = useState(false);
  const [ratesMessage, setRatesMessage] = useState<string | null>(null);
  const [ratesMessageKind, setRatesMessageKind] = useState<"ok" | "error">("error");
  const [chatEntries, setChatEntries] = useState<ChatCalculatorEntry[]>([]);
  const [editingEntryId, setEditingEntryId] = useState<string | null>(null);
  const [editFacturado, setEditFacturado] = useState("");
  const [editInvertido, setEditInvertido] = useState("");
  // Investment rates of the entry being edited (what the admin typed), see crm_corregir_tasas_entrada_calculadora (236).
  const [editBuy, setEditBuy] = useState("");
  const [editCup, setEditCup] = useState("");
  // USDT cost of one recharge / of one 360 CUP saldo package (RECARGA, SALDO_MOVIL), migration 242.
  const [editCost, setEditCost] = useState("");
  const [editSaving, setEditSaving] = useState(false);
  const [entryActionMessage, setEntryActionMessage] = useState<{ entryId: string; text: string } | null>(null);
  // Weekly cut (227): the latest cut hides the entries it archived; a live event for one of them must not bring it back.
  const [cutAt, setCutAt] = useState<string | null>(null);
  const [clearing, setClearing] = useState(false);
  const [clearDialogOpen, setClearDialogOpen] = useState(false);
  // Inline delete confirmation: one row at a time; `deletingEntryId` is the request in flight.
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null);
  const [deletingEntryId, setDeletingEntryId] = useState<string | null>(null);
  const [clearMessage, setClearMessage] = useState<string | null>(null);
  // The debounced autosave must not race the cut: a pending or in-flight save of the old text would write it back into
  // the document the cut just emptied.
  const clearingRef = useRef(false);
  const saveAbortRef = useRef<AbortController | null>(null);
  const [saveNonce, setSaveNonce] = useState(0);
  // No local theme state: the page reads the CRM's design tokens, so it
  // follows whatever mode and accent the operator picked in Appearance.
  // The old `dark` boolean and its "🌗 Tema" button were a second switch
  // that only knew light/dark, which is how this screen ended up white on
  // a dark CRM.
  const [fullscreen, setFullscreen] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  // "Registrar": the text box only ADDS operations. `registering` is the request in flight; the box is read-only meanwhile.
  const [registering, setRegistering] = useState(false);
  const [registerError, setRegisterError] = useState<string | null>(null);
  const [registerMessage, setRegisterMessage] = useState<string | null>(null);

  const tarifa = rates?.cupGlobalRate == null ? "" : String(rates.cupGlobalRate);
  // The ARQ USD -> MXN rate is read-only here: the two cron steps in migration 297 write it.
  const arqValor = arqValueOf(arqRate);
  const arqMinutes = arqRate?.edad_min == null ? null : Number(arqRate.edad_min);
  const arqStale = arqMinutes != null && Number.isFinite(arqMinutes) && arqMinutes >= ARQ_STALE_MINUTES;
  const arqAsk = arqRate ? arqAskLabel(arqRate) : null;
  const arqTime = arqRate ? arqTimeLabel(arqRate.fecha_arq) : null;
  // Migration 298: the last ARQ attempt can fail while a fallback value keeps the row fresh.
  const arqFailed = arqRate?.ultimo_arq_ok === false
    || (Number(arqRate?.fallos_arq_consecutivos) || 0) >= 1;
  const arqMotivo = arqRate?.ultimo_motivo ?? null;
  const selectedRateValue = rateValueOf(rates, selectedRate);
  const openRate = editingRate && editingRate.rates === rates ? editingRate.key : null;
  const rateInputValue = rateDraft ?? (selectedRateValue == null ? "" : String(selectedRateValue));
  // Migration 228: the lines "Registrar" would add (with the Guyana day each belongs to) and the ones that stay in the box.
  const draft = useMemo(() => manualEntriesFromText(rawText, Number(tarifa), guyanaToday(new Date())), [rawText, tarifa]);
  // Totals and breakdown count the operations of the table (the bot's and the manual ones); the draft text is not one yet.
  const totals = useMemo(() => chatTotals(chatEntries), [chatEntries]);
  const serviceTotals = useMemo(() => {
    const byService = new Map<string, { name: string; service: string; fact: number; inv: number; ret: number }>();
    for (const entry of chatEntries) {
      if (entry.status !== "completed") continue;
      const category = ledgerServiceLabel(entry.service);
      const current = byService.get(category) ?? { name: category, service: entry.service, fact: 0, inv: 0, ret: 0 };
      current.fact += entry.facturadoGyd ?? 0;
      current.inv += entry.invertidoGyd ?? 0;
      current.ret += entry.retornoGyd ?? 0;
      byService.set(category, current);
    }
    return [...byService.values()];
  }, [chatEntries]);
  const pendingEntries = useMemo(
    () => chatEntries.filter((entry) => entry.status === "verified_pending"),
    [chatEntries],
  );

  // Escape cancels the open delete confirmation (not while its request runs).
  useEffect(() => {
    if (!confirmingDeleteId || deletingEntryId) return;
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") setConfirmingDeleteId(null);
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [confirmingDeleteId, deletingEntryId]);

  // Lo que el servidor tiene guardado. El autosave solo escribe cuando el
  // texto o el periodo cambian de verdad: antes, cada visita re-firmaba el
  // documento (updated_by/updated_at) aunque no se hubiera tocado nada.
  const lastSavedRef = useRef<{ raw: string; periodo: string } | null>(null);

  function applyRates(next: CalculatorRates | null) {
    setRates(next);
    setRateDraft(null);
  }

  useEffect(() => {
    let active = true;
    Promise.all([
      fetch(`/api/calculadora?t=${Date.now()}`, { cache: "no-store" }).then((response) => {
        if (!response.ok) throw new Error("calculator document read failed");
        return response.json() as Promise<{
          rawText?: string;
          periodo?: string;
          cutAt?: string | null;
          chatOperations?: { entries?: ChatCalculatorEntry[] };
        }>;
      }),
      // Rates are read from their own endpoint (the same one Guardar tasas
      // writes to) so the page always has the current version id to send
      // back as expectedVersionId. A failure here is non-fatal: the rate
      // inputs just stay empty rather than blocking the whole page.
      fetch("/api/calculator/rates", { cache: "no-store" })
        .then((response) => {
          if (!response.ok) throw new Error("calculator rates read failed");
          return response.json() as Promise<{ rates: CalculatorRates | null; arqRate?: ArqRateInfo | null }>;
        })
        .catch(() => ({ rates: null, arqRate: null })),
    ])
      .then(([data, ratesData]) => {
        if (!active) return;
        setRawText(data.rawText ?? "");
        setPeriodo(data.periodo ?? "");
        setChatEntries(data.chatOperations?.entries ?? []);
        setCutAt(data.cutAt ?? null);
        applyRates(ratesData.rates);
        setArqRate(ratesData.arqRate ?? null);
        lastSavedRef.current = { raw: data.rawText ?? "", periodo: data.periodo ?? "" };
        localStorage.setItem(STORAGE_KEYS.raw, data.rawText ?? "");
        localStorage.setItem(STORAGE_KEYS.period, data.periodo ?? "");
      })
      .catch(() => {
        if (!active) return;
        const raw = localStorage.getItem(STORAGE_KEYS.raw) ?? "";
        const periodo = localStorage.getItem(STORAGE_KEYS.period) ?? "";
        setRawText(raw);
        setPeriodo(periodo);
        // Sin lectura del servidor no sabemos que coincidan: se deja null
        // para que el primer autosave sí escriba.
        lastSavedRef.current = null;
        setChatEntries([]);
      })
      .finally(() => { if (active) setHydrated(true); });
    return () => { active = false; };
  }, []);

  // The autosave keeps the draft text (and the period); it never registers an operation.
  useEffect(() => {
    if (!hydrated) return;
    localStorage.setItem(STORAGE_KEYS.raw, rawText);
    localStorage.setItem(STORAGE_KEYS.period, periodo);
    const timer = window.setTimeout(() => {
      if (clearingRef.current) return;
      const last = lastSavedRef.current;
      if (last && last.raw === rawText && last.periodo === periodo) return;
      const controller = new AbortController();
      saveAbortRef.current = controller;
      void fetch("/api/calculadora", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rawText, periodo }),
        signal: controller.signal,
      }).then((response) => {
        if (!response.ok) throw new Error("calculator document save failed");
        lastSavedRef.current = { raw: rawText, periodo };
        setSaveError(null);
      }).catch((error: unknown) => {
        if ((error as { name?: string } | null)?.name === "AbortError") return;
        setSaveError("No se pudo guardar en el servidor; los datos siguen guardados localmente.");
      });
    }, 600);
    return () => window.clearTimeout(timer);
  }, [hydrated, rawText, periodo, saveNonce]);

  // B4.2 — live updates for the operations table, no page refresh: a
  // remesa completed (or voided) elsewhere folds straight into
  // `chatEntries` from the realtime payload itself, never a refetch.
  // Gated on `hydrated` so a live event can't race the initial load's own
  // `setChatEntries`. Requires `remittance_calculator_entries` in the
  // `supabase_realtime` publication (migration 145).
  useCalculatorEntriesRealtime({
    enabled: hydrated,
    onEntryEvent: (event) => {
      setChatEntries((prev) => applyCalculatorEntryRealtimeEvent(prev, event.eventType, event.new, event.old, cutAt));
    },
  });

  async function actualizarTasa() {
    const value = Number(rateInputValue);
    if (rateInputValue.trim() === "" || !Number.isFinite(value) || value <= 0) {
      setRatesMessageKind("error");
      setRatesMessage("Escribe un número mayor que 0.");
      return;
    }
    setRatesSaving(true);
    setRatesMessage(null);
    try {
      // Only the selected rate is sent: the RPC carries every other rate forward from the current version.
      const response = await fetch("/api/calculator/rates", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          rates: { [selectedRate]: value },
          ...(rates?.id ? { expectedVersionId: rates.id } : {}),
        }),
      });
      if (response.status === 403) {
        setRatesLocked(true);
        setRatesMessageKind("error");
        setRatesMessage("Solo un administrador puede modificar las tasas.");
        return;
      }
      if (response.status === 409) {
        setRatesMessageKind("error");
        setRatesMessage("Las tasas se modificaron en otro lugar; recarga la página.");
        return;
      }
      if (!response.ok) {
        setRatesMessageKind("error");
        setRatesMessage("No se pudieron guardar las tasas.");
        return;
      }
      const data = await response.json() as { rates: CalculatorRates };
      applyRates(data.rates);
      setRatesMessageKind("ok");
      setRatesMessage("Tasa actualizada.");
    } catch {
      setRatesMessageKind("error");
      setRatesMessage("No se pudieron guardar las tasas.");
    } finally {
      setRatesSaving(false);
    }
  }


  function parseEditAmount(value: string): number | null {
    if (value.trim() === "") return null;
    const parsed = Number(value);
    if (!Number.isFinite(parsed) || parsed < 0) return null;
    return parsed;
  }

  function startEditEntry(entry: ChatCalculatorEntry) {
    // Only one row edits at a time -- opening this row's editor discards
    // any other row's in-progress edit and message.
    setConfirmingDeleteId(null);
    setEditingEntryId(entry.id);
    setEditFacturado(entry.facturadoGyd == null ? "" : String(entry.facturadoGyd));
    setEditInvertido(entry.invertidoGyd == null ? "" : String(entry.invertidoGyd));
    const prefill = prefillRates(entry);
    setEditBuy(prefill.buy == null ? "" : String(prefill.buy));
    setEditCup(prefill.cup == null ? "" : String(prefill.cup));
    setEditCost(prefill.cost == null ? "" : String(prefill.cost));
    setEntryActionMessage(null);
  }

  /**
   * The rates the editor starts from. A row that has a snapshot (or rates stored by an earlier edit) starts from its own. A manual row
   * with none starts from the rates its typed line was quoted with (read by the Calculator's own line parser); only a line that
   * carries none falls back to the CURRENT global investment rates, and with none loaded the fields start empty.
   */
  function prefillRates(entry: ChatCalculatorEntry): { buy: number | null; cup: number | null; cost: number | null; unstored: boolean } {
    const unstored = entry.source === "manual" && entry.usdtBuyGyd == null;
    if (!unstored) return { buy: entry.usdtBuyGyd ?? null, cup: entry.cupRate ?? null, cost: entry.costGyd ?? null, unstored };
    const line = parseManualLineRates(entry.rawLine);
    // A manual RECARGA / SALDO MOVIL line is quoted "(cost / sale / buy)": its own cost and buy rate (parseManualUnitLine).
    const unit = parseManualUnitLine(entry.rawLine);
    return {
      buy: line?.buy ?? unit?.buy ?? rates?.usdtBuyGyd ?? null,
      cup: line?.cupRate ?? rates?.usdtSellCup ?? null,
      cost: entry.costGyd ?? unit?.cost ?? null,
      unstored,
    };
  }

  function closeEditor() {
    setEditingEntryId(null);
    setEditFacturado("");
    setEditInvertido("");
    setEditBuy("");
    setEditCup("");
    setEditCost("");
  }

  /** A rate field: null when empty or not a number above zero. */
  function parseEditRate(value: string): number | null {
    if (value.trim() === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  }

  /**
   * The investment rates typed for `entry` against the ones it was costed with. `invalid` is a typed rate that is not above
   * zero; `changed` carries only the rates that differ (what the rates route gets); `recomputed` is the invertido the
   * database will store for them.
   */
  function editedRates(entry: ChatCalculatorEntry) {
    const editable = { ...canEditEntryRates(entry), cost: canEditEntryCost(entry) };
    const changed: { usdtBuyGyd?: number; cupRate?: number; costoUsdt?: number } = {};
    let invalid = false;
    const base = prefillRates(entry);
    // A manual row's prefill is not a stored rate (it is the line's quote or the global one): an empty field means "no rate change" there, not an invalid one.
    const optional = base.unstored;
    if (editable.buy) {
      const buy = parseEditRate(editBuy);
      if (buy === null) invalid = invalid || !(optional && editBuy.trim() === "");
      else if (buy !== base.buy) changed.usdtBuyGyd = buy;
    }
    if (editable.cup) {
      const cup = parseEditRate(editCup);
      if (cup === null) invalid = invalid || !(optional && editCup.trim() === "");
      else if (cup !== base.cup) changed.cupRate = cup;
    }
    if (editable.cost) {
      const cost = parseEditRate(editCost);
      if (cost === null) invalid = invalid || !(optional && editCost.trim() === "");
      else if (cost !== base.cost) changed.costoUsdt = cost;
    }
    // A row without a snapshot needs every rate its formula uses, so a change sends the whole set (CUP: both; others: buy; recharge / saldo: cost and buy).
    if (optional && Object.keys(changed).length > 0) {
      const buy = parseEditRate(editBuy);
      const cup = parseEditRate(editCup);
      const cost = parseEditRate(editCost);
      if (editable.buy && buy !== null) changed.usdtBuyGyd = buy;
      if (editable.cup && cup !== null) changed.cupRate = cup;
      if (editable.cost && cost !== null) changed.costoUsdt = cost;
    }
    const hasChange = Object.keys(changed).length > 0;
    const recomputed = hasChange && !invalid
      ? recomputeInvestment(
          {
            source: entry.source, status: entry.status, service: entry.service, amount: entry.amount, facturadoGyd: entry.facturadoGyd,
            cupRate: entry.cupRate ?? null, usdtBuyGyd: entry.usdtBuyGyd ?? null, costGyd: base.cost,
            basisGyd: entry.basisGyd ?? null, saleGyd: entry.saleGyd ?? null,
            discountPct: entry.source === "manual" ? (parseManualLineRates(entry.rawLine)?.discountPct ?? null) : null,
          },
          { usdtBuyGyd: changed.usdtBuyGyd, cupRate: changed.cupRate, costUsdt: changed.costoUsdt },
        )
      : null;
    return { editable, changed, hasChange, invalid, recomputed };
  }

  function cancelEditEntry() {
    closeEditor();
    setEntryActionMessage(null);
  }

  async function saveEditEntry(entryId: string) {
    const facturadoGyd = parseEditAmount(editFacturado);
    const invertidoGyd = parseEditAmount(editInvertido);
    if (facturadoGyd === null || invertidoGyd === null) {
      setEntryActionMessage({
        entryId,
        text: "Ingresa valores numéricos válidos (mayores o iguales a 0).",
      });
      return;
    }
    const target = chatEntries.find((entry) => entry.id === entryId);
    const rates = target ? editedRates(target) : null;
    if (target && rates) {
      if (rates.invalid) {
        setEntryActionMessage({ entryId, text: "Las tasas deben ser números mayores que 0." });
        return;
      }
      if (rates.hasChange) {
        await saveEditRates(target, rates.changed, facturadoGyd);
        return;
      }
    }
    setEditSaving(true);
    try {
      const response = await fetch(`/api/calculator/entries/${entryId}/correct`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ facturadoGyd, invertidoGyd }),
      });
      if (response.status === 403) {
        setEntryActionMessage({ entryId, text: "Solo un administrador puede corregir esta operación." });
        closeEditor();
        return;
      }
      if (!response.ok) {
        const data = await response.json().catch(() => ({}) as { error?: string });
        setEntryActionMessage({
          entryId,
          text: (data as { error?: string }).error ?? "No se pudo corregir la operación.",
        });
        return;
      }
      const data = (await response.json()) as { entry: StoredEntryFigures };
      applyStoredEntry(data.entry);
      setEntryActionMessage(null);
      closeEditor();
    } catch {
      setEntryActionMessage({ entryId, text: "No se pudo corregir la operación." });
    } finally {
      setEditSaving(false);
    }
  }

  /**
   * Saves the investment rates of an entry (the database recomputes invertido and retorno). If the admin also changed the
   * facturado, it is then corrected over the invertido the rates produced, with the existing figures route.
   */
  async function saveEditRates(entry: ChatCalculatorEntry, changed: { usdtBuyGyd?: number; cupRate?: number; costoUsdt?: number }, facturadoGyd: number) {
    const entryId = entry.id;
    setEditSaving(true);
    try {
      const response = await fetch(`/api/calculator/entries/${entryId}/rates`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(changed),
      });
      if (response.status === 403) {
        setEntryActionMessage({ entryId, text: "Solo un administrador puede corregir las tasas de esta operación." });
        closeEditor();
        return;
      }
      if (!response.ok) {
        const data = await response.json().catch(() => ({}) as { error?: string });
        setEntryActionMessage({
          entryId,
          text: (data as { error?: string }).error ?? "No se pudieron corregir las tasas de la operación.",
        });
        return;
      }
      const data = (await response.json()) as { entry: StoredEntryFigures };
      applyStoredEntry(data.entry);
      if (facturadoGyd !== entry.facturadoGyd) {
        const correction = await fetch(`/api/calculator/entries/${entryId}/correct`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ facturadoGyd, invertidoGyd: data.entry.invertidoGyd }),
        });
        if (!correction.ok) {
          const failure = await correction.json().catch(() => ({}) as { error?: string });
          setEntryActionMessage({
            entryId,
            text: `Las tasas se guardaron, pero no se pudo corregir el facturado: ${(failure as { error?: string }).error ?? "error desconocido"}`,
          });
          closeEditor();
          return;
        }
        applyStoredEntry(((await correction.json()) as { entry: StoredEntryFigures }).entry);
      }
      setEntryActionMessage(null);
      closeEditor();
    } catch {
      setEntryActionMessage({ entryId, text: "No se pudieron corregir las tasas de la operación." });
    } finally {
      setEditSaving(false);
    }
  }

  /** Folds the row the server answered (figures, status and, when present, the rate snapshot) into the table. */
  function applyStoredEntry(stored: StoredEntryFigures) {
    setChatEntries((prev) =>
      prev.map((entry) =>
        entry.id === stored.id
          ? {
              ...entry,
              facturadoGyd: stored.facturadoGyd,
              invertidoGyd: stored.invertidoGyd,
              retornoGyd: stored.retornoGyd,
              status: stored.status as ChatCalculatorEntry["status"],
              ...(stored.usdtBuyGyd !== undefined
                ? {
                    cupGlobalRate: stored.cupGlobalRate, cupRate: stored.cupRate, usdtBuyGyd: stored.usdtBuyGyd,
                    usdtSellGyd: stored.usdtSellGyd, costGyd: stored.costGyd, basisGyd: stored.basisGyd, saleGyd: stored.saleGyd,
                  }
                : {}),
            }
          : entry,
      ),
    );
  }

  function handleEditKeys(event: KeyboardEvent<HTMLInputElement>, entryId: string) {
    if (event.key === "Enter") {
      event.preventDefault();
      if (!editSaving) void saveEditEntry(entryId);
    } else if (event.key === "Escape") {
      event.preventDefault();
      if (!editSaving) cancelEditEntry();
    }
  }

  function handleTextChange(event: ChangeEvent<HTMLTextAreaElement>) {
    const textarea = event.currentTarget;
    const cursor = textarea.selectionStart;
    const currentLine = textarea.value.slice(lineStart(textarea.value, cursor), cursor);
    if (currentLine === "- ") {
      setRawText(`${textarea.value.slice(0, lineStart(textarea.value, cursor))}• ${textarea.value.slice(cursor)}`);
      return;
    }
    setRawText(textarea.value);
  }

  function handleKeys(event: KeyboardEvent<HTMLTextAreaElement>) {
    const textarea = event.currentTarget;
    const cursor = textarea.selectionStart;
    const start = lineStart(rawText, cursor);
    const currentLine = rawText.slice(start, cursor);
    if (event.key === " ") {
      const line = rawText.slice(start, cursor);
      if (line === "-") {
        event.preventDefault();
        setRawText(`${rawText.slice(0, start)}• ${rawText.slice(cursor)}`);
        window.requestAnimationFrame(() => { textarea.selectionStart = textarea.selectionEnd = start + 2; });
        return;
      }
    }
    if (event.key !== "Enter" || !currentLine.startsWith("•")) return;
    event.preventDefault();
    if (currentLine === "• " || currentLine === "•") {
      setRawText(`${rawText.slice(0, start)}${rawText.slice(cursor)}`);
      window.requestAnimationFrame(() => { textarea.selectionStart = textarea.selectionEnd = start; });
      return;
    }
    setRawText(`${rawText.slice(0, cursor)}\n• ${rawText.slice(cursor)}`);
    window.requestAnimationFrame(() => { textarea.selectionStart = textarea.selectionEnd = cursor + 3; });
  }

  function insertManualBullet() {
    const textarea = document.getElementById("rawText") as HTMLTextAreaElement | null;
    if (!textarea) return;
    const result = insertBullet(rawText, textarea.selectionStart);
    setRawText(result.value);
    window.requestAnimationFrame(() => { textarea.selectionStart = textarea.selectionEnd = result.cursor; textarea.focus(); });
  }

  function toggleFullscreen() {
    setFullscreen((value) => !value);
  }

  async function clearAll() {
    if (clearing) return;
    setClearing(true);
    setClearMessage(null);
    // Stop the autosave first: neither a pending nor an in-flight save may write the old text after the cut.
    clearingRef.current = true;
    saveAbortRef.current?.abort();
    try {
      // The global rates are DB-managed (calculator_rate_versions), shared across weeks -- the cut does not touch them.
      const response = await fetch("/api/calculadora/weeks", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        // The totals of both kinds of operation are computed in the database; the draft text is archived as it is.
        body: JSON.stringify({ rawText, periodo }),
      });
      if (!response.ok) {
        setClearMessage("No se pudo limpiar la semana; no se borró nada.");
        setSaveNonce((value) => value + 1);
        return;
      }
      const data = (await response.json()) as { cutAt?: string | null };
      setCutAt(data.cutAt ?? new Date().toISOString());
      // Archived with the week: every completed operation (the bot's and the manual ones). A line still waiting for a price is never archived.
      setChatEntries((prev) => prev.filter((entry) => entry.status === "verified_pending"));
      setRawText("");
      setPeriodo("");
      localStorage.removeItem(STORAGE_KEYS.raw);
      localStorage.removeItem(STORAGE_KEYS.period);
    } catch {
      setClearMessage("No se pudo limpiar la semana; no se borró nada.");
      setSaveNonce((value) => value + 1);
    } finally {
      clearingRef.current = false;
      setClearing(false);
      setClearDialogOpen(false);
    }
  }

  async function registrar() {
    if (registering || clearingRef.current) return;
    const sent = rawText;
    const { lines } = manualEntriesFromText(sent, Number(tarifa), guyanaToday(new Date()));
    if (lines.length === 0) return;
    setRegistering(true);
    setRegisterError(null);
    setRegisterMessage(null);
    try {
      const response = await fetch("/api/calculadora/entries", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          lines: lines.map((line) => ({
            date: line.date, dayLabel: line.dayLabel, customer: line.customer, service: line.service, amount: line.amount,
            currency: line.currency, facturadoGyd: line.facturadoGyd, invertidoGyd: line.invertidoGyd,
            retornoGyd: line.retornoGyd, rawLine: line.rawLine,
          })),
        }),
      });
      if (!response.ok) {
        setRegisterError(
          response.status === 403
            ? "No tienes permiso para registrar operaciones."
            : "No se pudieron registrar las operaciones; no se quitó nada del cuadro.",
        );
        return;
      }
      const data = (await response.json()) as { entries?: ChatCalculatorEntry[] };
      setChatEntries((prev) => (data.entries ?? []).reduce((list, entry) => insertCalculatorEntry(list, entry), prev));
      const count = lines.length;
      setRegisterMessage(count === 1 ? "1 operación registrada." : `${count} operaciones registradas.`);
      if (rawText === sent) {
        setRawText(removeRegisteredLines(sent, lines.map((line) => line.line)));
      } else {
        setRegisterError("Las operaciones se registraron, pero el cuadro cambió mientras tanto: borra a mano las líneas ya registradas.");
      }
    } catch {
      setRegisterError("No se pudieron registrar las operaciones; no se quitó nada del cuadro.");
    } finally {
      setRegistering(false);
    }
  }

  async function deleteEntry(entry: ChatCalculatorEntry) {
    if (deletingEntryId) return;
    setEntryActionMessage(null);
    setDeletingEntryId(entry.id);
    try {
      const response = await fetch(`/api/calculator/entries/${entry.id}/delete`, { method: "POST" });
      if (response.status === 403) {
        setEntryActionMessage({ entryId: entry.id, text: "Solo un administrador puede eliminar esta operación." });
        return;
      }
      if (!response.ok) {
        const data = (await response.json().catch(() => ({}))) as { error?: string };
        setEntryActionMessage({ entryId: entry.id, text: data.error ?? "No se pudo eliminar la operación." });
        return;
      }
      setChatEntries((prev) => prev.filter((item) => item.id !== entry.id));
    } catch {
      setEntryActionMessage({ entryId: entry.id, text: "No se pudo eliminar la operación." });
    } finally {
      setDeletingEntryId(null);
      setConfirmingDeleteId(null);
    }
  }

  function exportar() {
    const title = periodo || "Sin_Periodo";
    const operationsText = chatEntries
      .map((entry) => `• ${entry.entryDate.slice(0, 10)} ${entry.customerName || "Sin nombre"} ${chatEntryAmountExportText(entry)}${entry.source === "manual" ? " (manual)" : ""} [${entry.status}]`)
      .join("\n");
    const draftText = rawText.trim() === "" ? "" : `=== REGISTRO MANUAL EN BRUTO (SIN REGISTRAR) ===\n${rawText}\n\n`;
    const text = `=== CIERRE SEMANAL DE REMESAS ===\nPERIODO: ${periodo}\n--------------------------------\n\nTOTAL FACTURADO (GYD): ${plainNumber(totals.fact)}\nTOTAL INVERTIDO (GYD): ${plainNumber(totals.inv)}\nRETORNO NETO (GANANCIA): ${plainNumber(totals.ret)}\n\n${draftText}=== OPERACIONES ===\n${operationsText}`;
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    link.download = `Cierre_${title.replace(/\s/g, "_")}.txt`;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  // Header actions of the overview: they reuse the calculator's own box, rates block and weekly-cut dialog.
  function focusRegisterBox() {
    const box = document.getElementById("rawText");
    box?.scrollIntoView({ behavior: "smooth", block: "center" });
    box?.focus({ preventScroll: true });
  }

  function startEditRate(key: RateKey) {
    setSelectedRate(key);
    setRateDraft(null);
    setRatesMessage(null);
    setEditingRate({ key, rates });
  }

  function cancelEditRate() {
    setEditingRate(null);
    setRateDraft(null);
    setRatesMessage(null);
  }

  const arqNote = arqStale
    ? `sin actualizar desde ${arqAgeLabel(arqMinutes!)}`
    : arqFailed
      ? `último intento ARQ falló${arqMotivo ? ` (${arqMotivo})` : ""}`
      : [arqAsk, arqMinutes != null && Number.isFinite(arqMinutes) ? arqAgeLabel(arqMinutes) : null, arqTime].filter(Boolean).join(" · ");

  return (
    <>
    <SemanaOverview
      entries={chatEntries}
      cutAt={cutAt}
      ready={hydrated}
      onRegister={focusRegisterBox}
      onCloseWeek={() => { if (!clearing) setClearDialogOpen(true); }}
    />
    <RatesCard
      rates={rates}
      arq={arqValor == null ? null : { value: arqValor, note: arqNote, warn: arqStale || arqFailed, ageLabel: arqMinutes != null && Number.isFinite(arqMinutes) ? arqAgeLabel(arqMinutes) : null }}
      editing={openRate}
      draft={rateInputValue}
      locked={ratesLocked}
      saving={ratesSaving}
      message={ratesMessage ? { text: ratesMessage, kind: ratesMessageKind } : null}
      onStartEdit={startEditRate}
      onDraftChange={setRateDraft}
      onSave={() => void actualizarTasa()}
      onCancel={cancelEditRate}
    />
    <div className="legacyCalc legacyEmbedded">
      <div className="legacyContainer">
        <div className="legacyTopBar">
          <h1>Cierre Semanal PRO</h1>
        </div>

        <details>
          <summary>Guía Rápida de Formatos de Registro</summary>
          <table className="legacyHelpTable"><thead><tr><th>Servicio</th><th>Ejemplo</th><th>Cálculo</th></tr></thead><tbody>
            <tr><td><b>CUP</b></td><td><code>• Fran 50k CUP (235/980)</code></td><td>Tarifa global para venta; paréntesis para costo.</td></tr>
            <tr><td><b>Zelle / MLC / Clásica / Tropical</b></td><td><code>• Pedro 150 MLC (30%/240/245)</code><br /><code>• Julié 2.8k Zelle (3%/235/250)</code></td><td>Aplica % descuento (si hay) y costo/venta en GYD.</td></tr>
            <tr><td><b>USDT</b></td><td><code>• Carlos 1k usdt (235/260)</code></td><td>Costo y venta directos en GYD por USDT.</td></tr>
            <tr><td><b>Recargas Promo</b></td><td><code>• Josefa 1 rec promo (23.1/6.2k/242)</code></td><td><code>(USDT Costo / Venta GYD / Tasa USDT GYD)</code></td></tr>
            <tr><td><b>Saldo móvil</b></td><td><code>• Carlos 2 saldo movil (1.25/1k/242.21)</code></td><td><code>(USDT Costo / Venta GYD / Tasa USDT GYD)</code></td></tr>
            <tr><td><b>Servicios Directos</b></td><td><code>• Iza 1 ext visa 5k GYD</code></td><td><b>Ganancia limpia:</b> Inv = 0, Retorno = Monto.</td></tr>
          </tbody></table>
        </details>

        <div className="legacyCard legacyFlex">
          <div><label htmlFor="periodo">Período / Semana</label><input id="periodo" placeholder="Ej. SEMANA 1 AGOSTO" value={periodo} onChange={(event) => setPeriodo(event.target.value)} /></div>
        </div>

        {pendingEntries.length > 0 && (
          <div className="legacyWarning" id="pendingBanner">
            <p style={{ margin: "0 0 6px 0", fontWeight: "bold" }}>
              {pendingEntries.length} operación{pendingEntries.length === 1 ? "" : "es"} del chat en espera {pendingEntries.every(isComboCostPending) ? "del costo" : "de tasas"} para completarse:
            </p>
            <ul style={{ margin: 0, paddingLeft: 18 }}>
              {pendingEntries.map((entry) => (
                <li key={entry.id}>
                  {entry.customerName || "Sin nombre"} ({ledgerServiceLabel(entry.service)}): {pendingReason(entry)}
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className={`legacyCard${fullscreen ? " legacyFullscreen" : ""}`} id="cardRegistros">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10, gap: 10 }}>
            <h2 style={{ margin: 0 }}>Registros de la Semana</h2>
            <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
              <button type="button" id="registrarEntradas" onClick={() => void registrar()} disabled={registering || draft.lines.length === 0} aria-busy={registering} style={{ width: "auto", padding: "6px 12px", fontSize: 13, minHeight: 36 }}>Registrar</button>
              <button type="button" onClick={toggleFullscreen} style={{ width: "auto", padding: "6px 12px", fontSize: 13, minHeight: 36, background: fullscreen ? "#dc3545" : "var(--legacy-accent)" }}>{fullscreen ? "Salir de Pantalla Completa" : "Maximizar"}</button>
            </div>
          </div>
          <span className="legacySmall">Usa el botón <b>+ Viñeta</b> o escribe <code>-</code> + <code>Espacio</code>. Presiona <code>Enter</code> para nueva línea.</span>
          <textarea id="rawText" value={rawText} readOnly={registering} onChange={handleTextChange} onKeyDown={handleKeys} placeholder={'Miércoles 5\n• Fran 50k CUP (235/980)\n• Josefa 1 rec promo (23.1/6.2k/242)\n• Pedro 150 MLC (30%/240/245)\n• Carlos 2 saldo movil (1.25/1k/242.21)\n• Carlos 1k usdt (235/260)\n• Iza 1 ext visa 5k GYD'} />
          <button type="button" className="legacyBulletButton" onClick={insertManualBullet}>+ Viñeta •</button>
        </div>

        {saveError && <div className="legacyError">{saveError}</div>}
        {registerError && <div className="legacyError" role="status">{registerError}</div>}
        {registerMessage && <div className="legacyNotice" role="status">{registerMessage}</div>}
        {draft.uninterpreted.length > 0 && (
          <div className="legacyWarning" id="lineasNoInterpretadas">
            {draft.uninterpreted.map((item) => <p key={item.line} style={{ margin: "0 0 4px 0", color: "orange" }}>No interpretado: &quot;{item.raw}&quot;</p>)}
          </div>
        )}

        <div className="legacyTotals">
          <TotalBox title="Facturado (GYD)" kind="in" value={totals.fact} />
          <TotalBox title="Invertido (GYD)" kind="out" value={totals.inv} />
          <TotalBox title="Retorno Neto (GYD)" kind="result" value={totals.ret} />
        </div>

        <div className="legacyCard"><h2>Desglose Semanal por Servicios</h2>{serviceTotals.map((service) => <div className="legacyCard" style={{ marginBottom: 10, padding: 12 }} key={service.name}><div className="legacyBlockRow"><b><ServiceDot service={service.service} />Categoría: {service.name}</b><span>Fact: <b>{formatNumber(service.fact)} GYD</b> | Inv: <b>{formatNumber(service.inv)} GYD</b> | Retorno: <b {...moneyCellProps(profitTone(service.ret))}>{formatNumber(service.ret)} GYD</b></span></div></div>)}</div>

        <div className="legacyCard">
          <h2>Operaciones</h2>
          {chatEntries.length === 0 ? (
            <span className="legacySmall">No hay operaciones.</span>
          ) : (
            <div style={{ maxHeight: 400, overflowY: "auto" }}>
              <table className="legacyParsedTable">
                <thead>
                  <tr>
                    <th>Fecha</th><th>Cliente</th><th>Monto</th><th>Tipo</th><th>Estado</th>
                    <th>Fact. (GYD)</th><th>Inv. (GYD)</th><th>Ganancia</th><th className="legacyActionsCell">Acciones</th>
                  </tr>
                </thead>
                <tbody>
                  {chatEntries.map((entry) => {
                    const editing = editingEntryId === entry.id;
                    const rowMessage = entryActionMessage?.entryId === entry.id ? entryActionMessage.text : null;
                    const editedRate = editing ? editedRates(entry) : null;
                    // A changed rate drives invertido (the database recomputes it); otherwise the typed figure does.
                    const shownInvertido = editedRate?.recomputed ? editedRate.recomputed.invertidoGyd.toFixed(2) : editInvertido;
                    const editPreview = (Number(editFacturado) || 0) - (Number(shownInvertido) || 0);
                    return (
                      <Fragment key={entry.id}>
                      <tr>
                        <td data-label="Fecha">{entry.entryDate.slice(0, 10)}</td>
                        <td data-label="Cliente"><b>{entry.customerName || "—"}</b></td>
                        <td data-label="Monto">{chatEntryAmountText(entry)}</td>
                        <td data-label="Tipo"><span className="legacyBadge"><ServiceDot service={entry.service} />{ledgerServiceLabel(entry.service)}</span>{entry.source === "manual" && <span className="legacyBadge" title="Registrada a mano" style={{ marginLeft: 6 }}>Manual</span>}</td>
                        <td data-label="Estado">{entry.status === "completed" ? "Completada" : `Pendiente${entry.missingRates.length ? `: ${pendingReason(entry)}` : ""}`}</td>
                        <td data-label="Fact. (GYD)" {...(editing ? {} : moneyCellProps(entry.facturadoGyd == null ? "neutral" : "in"))}>
                          {editing ? (
                            <input
                              id={`editFacturado-${entry.id}`}
                              type="number"
                              step="0.01"
                              value={editFacturado}
                              onChange={(event) => setEditFacturado(event.target.value)}
                              onKeyDown={(event) => handleEditKeys(event, entry.id)}
                            />
                          ) : entry.facturadoGyd == null ? "—" : formatNumber(entry.facturadoGyd)}
                        </td>
                        <td data-label="Inv. (GYD)" {...(editing ? {} : moneyCellProps(entry.invertidoGyd == null ? "neutral" : "out"))}>
                          {editing ? (
                            <input
                              id={`editInvertido-${entry.id}`}
                              type="number"
                              step="0.01"
                              value={shownInvertido}
                              readOnly={Boolean(editedRate?.recomputed)}
                              disabled={Boolean(editedRate?.recomputed)}
                              onChange={(event) => setEditInvertido(event.target.value)}
                              onKeyDown={(event) => handleEditKeys(event, entry.id)}
                            />
                          ) : entry.invertidoGyd == null ? "—" : formatNumber(entry.invertidoGyd)}
                        </td>
                        <td data-label="Ganancia" {...moneyCellProps(profitTone(editing ? editPreview : entry.retornoGyd))}>
                          {editing ? formatNumber(editPreview) : entry.retornoGyd == null ? "—" : formatNumber(entry.retornoGyd)}
                        </td>
                        <td data-label="Acciones" className="legacyActionsCell">
                          {editing ? (
                            <div style={{ display: "flex", gap: 6, flexDirection: "column" }}>
                              <div style={{ display: "inline-flex", gap: 6, justifyContent: "center" }}>
                                <button
                                  type="button"
                                  id={`guardarEntry-${entry.id}`}
                                  className="legacyIconButton"
                                  onClick={() => void saveEditEntry(entry.id)}
                                  disabled={editSaving}
                                  aria-busy={editSaving}
                                  aria-label="Guardar"
                                  title="Guardar"
                                >
                                  {editSaving ? <Loader2 size={16} className="animate-spin" aria-hidden="true" /> : <Check size={16} aria-hidden="true" />}
                                </button>
                                <button
                                  type="button"
                                  id={`cancelarEntry-${entry.id}`}
                                  className="legacyIconButton"
                                  onClick={cancelEditEntry}
                                  disabled={editSaving}
                                  aria-label="Cancelar"
                                  title="Cancelar"
                                >
                                  <X size={16} aria-hidden="true" />
                                </button>
                              </div>
                              {rowMessage && <div className="legacyError">{rowMessage}</div>}
                            </div>
                          ) : confirmingDeleteId === entry.id ? (
                            <span style={{ display: "inline-flex", alignItems: "center", gap: 6, whiteSpace: "nowrap" }}>
                              <span>¿Eliminar?</span>
                              <button
                                type="button"
                                id={`cancelarEliminar-${entry.id}`}
                                className="legacyIconButton"
                                onClick={() => setConfirmingDeleteId(null)}
                                disabled={deletingEntryId === entry.id}
                                aria-label="Cancelar"
                                title="Cancelar"
                              >
                                <X size={16} aria-hidden="true" />
                              </button>
                              <button
                                type="button"
                                id={`confirmarEliminar-${entry.id}`}
                                className="legacyIconButton"
                                style={{ color: "var(--destructive)", borderColor: "var(--destructive)" }}
                                onClick={() => void deleteEntry(entry)}
                                disabled={deletingEntryId === entry.id}
                                aria-busy={deletingEntryId === entry.id}
                                aria-label="Eliminar"
                                title="Eliminar"
                              >
                                {deletingEntryId === entry.id ? <Loader2 size={16} className="animate-spin" aria-hidden="true" /> : <Check size={16} aria-hidden="true" />}
                              </button>
                            </span>
                          ) : (
                            <>
                              {entry.status === "completed" && (
                                <button
                                  type="button"
                                  id={`editarEntry-${entry.id}`}
                                  className="legacyIconButton"
                                  onClick={() => startEditEntry(entry)}
                                  aria-label="Editar"
                                  title="Editar"
                                >
                                  <Pencil size={16} aria-hidden="true" />
                                </button>
                              )}
                              <button
                                type="button"
                                id={`eliminarEntry-${entry.id}`}
                                className="legacyIconButton"
                                onClick={() => setConfirmingDeleteId(entry.id)}
                                aria-label="Eliminar"
                                title="Eliminar"
                              >
                                <Trash2 size={16} aria-hidden="true" />
                              </button>
                            </>
                          )}
                          {!editing && rowMessage && <div className="legacyError">{rowMessage}</div>}
                        </td>
                      </tr>
                      {editing && editedRate && (editedRate.editable.buy || editedRate.editable.cup || editedRate.editable.cost) && (
                        <tr id={`tasasEntry-${entry.id}`}>
                          <td colSpan={9}>
                            <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "flex-end" }}>
                              <span className="legacySmall">Tasas de esta operación:</span>
                              {entry.cupGlobalRate != null && <span className="legacySmall">Tarifa CUP: <b>{entry.cupGlobalRate}</b></span>}
                              {entry.usdtSellGyd != null && <span className="legacySmall">Venta USDT (GYD): <b>{entry.usdtSellGyd}</b></span>}
                              {editedRate.editable.cup && (
                                <label className="legacySmall" htmlFor={`editVentaUsdtCup-${entry.id}`}>
                                  Venta USDT (CUP)
                                  <input
                                    id={`editVentaUsdtCup-${entry.id}`}
                                    type="number"
                                    step="any"
                                    value={editCup}
                                    onChange={(event) => setEditCup(event.target.value)}
                                    onKeyDown={(event) => handleEditKeys(event, entry.id)}
                                  />
                                </label>
                              )}
                              {editedRate.editable.cost && (
                                <label className="legacySmall" htmlFor={`editCostoUsdt-${entry.id}`}>
                                  {entry.service === "SALDO_MOVIL" ? "Costo por 360 CUP (USDT)" : "Costo por recarga (USDT)"}
                                  <input
                                    id={`editCostoUsdt-${entry.id}`}
                                    type="number"
                                    step="any"
                                    value={editCost}
                                    onChange={(event) => setEditCost(event.target.value)}
                                    onKeyDown={(event) => handleEditKeys(event, entry.id)}
                                  />
                                </label>
                              )}
                              {editedRate.editable.buy && (
                                <label className="legacySmall" htmlFor={`editCompraUsdt-${entry.id}`}>
                                  Compra USDT (GYD)
                                  <input
                                    id={`editCompraUsdt-${entry.id}`}
                                    type="number"
                                    step="any"
                                    value={editBuy}
                                    onChange={(event) => setEditBuy(event.target.value)}
                                    onKeyDown={(event) => handleEditKeys(event, entry.id)}
                                  />
                                </label>
                              )}
                            </div>
                          </td>
                        </tr>
                      )}
                      </Fragment>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>

        <div className="legacyCard legacyFlex"><button type="button" onClick={exportar}>Exportar Reporte (.txt)</button><button type="button" className="legacySecondary" onClick={() => setClearDialogOpen(true)} disabled={clearing}>{clearing ? "Limpiando…" : "Limpiar Todo"}</button></div>
        {clearMessage && <div className="legacyError" role="status">{clearMessage}</div>}

        {/* Rendered in a portal on <body>, outside .legacyCalc, so the page's legacy button styles do not reach it. */}
        <Dialog open={clearDialogOpen} onOpenChange={(open) => { if (!clearing) setClearDialogOpen(open); }}>
          <DialogContent showCloseButton={false}>
            <DialogHeader>
              <DialogTitle>¿Limpiar todo y empezar una semana nueva?</DialogTitle>
              <DialogDescription>
                La semana actual se guarda en «Cierres» y el historial (Finanzas, panel) sigue contando. Las
                operaciones del chat en espera de precio se quedan en pantalla.
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <Button variant="ghost" onClick={() => setClearDialogOpen(false)} disabled={clearing}>Cancelar</Button>
              <Button variant="destructive" onClick={() => void clearAll()} disabled={clearing}>
                {clearing ? "Limpiando…" : "Limpiar todo"}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>

      </div>
    </div>
    </>
  );
}
