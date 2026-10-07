"use client";

import { useEffect, useMemo, useState, type ChangeEvent, type KeyboardEvent } from "react";
import { Pencil } from "lucide-react";
import { procesarTexto, type WebCalculatorErrorLine, type WebCalculatorParsedLine } from "@/lib/calculator/web-calculator";
import { isComboCostPending, pendingReason, type CalculatorRates } from "@/lib/calculator/ledger-read-model";
import { calculatorCategoryName, chatEntryAmountText, ledgerServiceLabel } from "@/lib/calculator/entry-display";
import { applyCalculatorEntryRealtimeEvent, type ChatCalculatorEntry } from "@/lib/calculator/realtime-entry";
import { useCalculatorEntriesRealtime } from "@/hooks/use-calculator-entries-realtime";
import "./calculadora.module.css";

const STORAGE_KEYS = {
  raw: "remesas_rawText",
  period: "remesas_periodo",
} as const;

function isErrorLine(operation: WebCalculatorParsedLine): operation is WebCalculatorErrorLine {
  return "error" in operation;
}

function formatNumber(value: number): string {
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

function renderOperationGroups(operations: WebCalculatorParsedLine[]) {
  const groups: Array<{ day: string; operations: WebCalculatorParsedLine[] }> = [];
  for (const operation of operations) {
    const day = operation.dia;
    const current = groups.at(-1);
    if (!current || current.day !== day) groups.push({ day, operations: [operation] });
    else current.operations.push(operation);
  }
  return groups;
}

type RateKey =
  | "cup_global_rate" | "usdt_buy_gyd" | "usdt_sell_gyd" | "usdt_sell_cup" | "zelle_sell_gyd"
  | "zelle_sell_gyd_1000" | "zelle_sell_gyd_2000" | "efectivo_usd_gyd" | "recarga_costo_usdt"
  | "saldo_costo_usdt";

// Every global rate, in the order shown in the dropdown and the current-rates list.
const RATE_FIELDS: ReadonlyArray<{ key: RateKey; label: string; field: keyof CalculatorRates }> = [
  { key: "cup_global_rate", label: "Tarifa CUP global", field: "cupGlobalRate" },
  { key: "usdt_buy_gyd", label: "Compra USDT (GYD)", field: "usdtBuyGyd" },
  { key: "usdt_sell_gyd", label: "Venta USDT (GYD)", field: "usdtSellGyd" },
  { key: "usdt_sell_cup", label: "Venta USDT (CUP)", field: "usdtSellCup" },
  { key: "zelle_sell_gyd", label: "Zelle desde 50 USD", field: "zelleSellGyd" },
  { key: "zelle_sell_gyd_1000", label: "Zelle desde 1,000 USD", field: "zelleSellGyd1000" },
  { key: "zelle_sell_gyd_2000", label: "Zelle desde 2,000 USD", field: "zelleSellGyd2000" },
  { key: "efectivo_usd_gyd", label: "Efectivo USD (GYD por dólar)", field: "efectivoUsdGyd" },
  { key: "recarga_costo_usdt", label: "Recarga: costo (USDT)", field: "recargaCostoUsdt" },
  { key: "saldo_costo_usdt", label: "Costo saldo (USDT)", field: "saldoCostoUsdt" },
];

function rateValueOf(rates: CalculatorRates | null, key: RateKey): number | null {
  const field = RATE_FIELDS.find((f) => f.key === key)!.field;
  return (rates?.[field] as number | null | undefined) ?? null;
}

export default function CalculadoraPage() {
  const [rawText, setRawText] = useState("");
  const [periodo, setPeriodo] = useState("");
  const [rates, setRates] = useState<CalculatorRates | null>(null);
  const [selectedRate, setSelectedRate] = useState<RateKey>("cup_global_rate");
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
  const [editSaving, setEditSaving] = useState(false);
  const [entryActionMessage, setEntryActionMessage] = useState<{ entryId: string; text: string } | null>(null);
  // No local theme state: the page reads the CRM's design tokens, so it
  // follows whatever mode and accent the operator picked in Appearance.
  // The old `dark` boolean and its "🌗 Tema" button were a second switch
  // that only knew light/dark, which is how this screen ended up white on
  // a dark CRM.
  const [fullscreen, setFullscreen] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const tarifa = rates?.cupGlobalRate == null ? "" : String(rates.cupGlobalRate);
  const selectedRateValue = rateValueOf(rates, selectedRate);
  const rateInputValue = rateDraft ?? (selectedRateValue == null ? "" : String(selectedRateValue));
  const parsed = useMemo(() => procesarTexto(rawText, Number(tarifa)), [rawText, tarifa]);
  const operationGroups = useMemo(() => renderOperationGroups(parsed.operations), [parsed.operations]);
  const structuredTotals = useMemo(() => chatTotals(chatEntries), [chatEntries]);
  const totals = useMemo(() => ({
    fact: parsed.totals.fact + structuredTotals.fact,
    inv: parsed.totals.inv + structuredTotals.inv,
    ret: parsed.totals.ret + structuredTotals.ret,
  }), [parsed.totals, structuredTotals]);
  const serviceTotals = useMemo(() => {
    const byService = new Map(parsed.services.map((service) => [service.name, { ...service }]));
    for (const entry of chatEntries) {
      if (entry.status !== "completed") continue;
      const category = calculatorCategoryName(entry.service);
      const current = byService.get(category) ?? { name: category, fact: 0, inv: 0, ret: 0 };
      current.fact += entry.facturadoGyd ?? 0;
      current.inv += entry.invertidoGyd ?? 0;
      current.ret += entry.retornoGyd ?? 0;
      byService.set(category, current);
    }
    return [...byService.values()];
  }, [chatEntries, parsed.services]);
  const pendingEntries = useMemo(
    () => chatEntries.filter((entry) => entry.status === "verified_pending"),
    [chatEntries],
  );

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
          return response.json() as Promise<{ rates: CalculatorRates | null }>;
        })
        .catch(() => ({ rates: null })),
    ])
      .then(([data, ratesData]) => {
        if (!active) return;
        setRawText(data.rawText ?? "");
        setPeriodo(data.periodo ?? "");
        setChatEntries(data.chatOperations?.entries ?? []);
        applyRates(ratesData.rates);
        localStorage.setItem(STORAGE_KEYS.raw, data.rawText ?? "");
        localStorage.setItem(STORAGE_KEYS.period, data.periodo ?? "");
      })
      .catch(() => {
        if (!active) return;
        setRawText(localStorage.getItem(STORAGE_KEYS.raw) ?? "");
        setPeriodo(localStorage.getItem(STORAGE_KEYS.period) ?? "");
        setChatEntries([]);
      })
      .finally(() => { if (active) setHydrated(true); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!hydrated) return;
    localStorage.setItem(STORAGE_KEYS.raw, rawText);
    localStorage.setItem(STORAGE_KEYS.period, periodo);
    const timer = window.setTimeout(() => {
      void fetch("/api/calculadora", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rawText, periodo }),
      }).then((response) => {
        if (!response.ok) throw new Error("calculator document save failed");
        setSaveError(null);
      }).catch(() => setSaveError("No se pudo guardar en el servidor; los datos siguen guardados localmente."));
    }, 600);
    return () => window.clearTimeout(timer);
  }, [hydrated, rawText, periodo]);

  // B4.2 — live updates for "Operaciones del chat", no page refresh: a
  // remesa completed (or voided) elsewhere folds straight into
  // `chatEntries` from the realtime payload itself, never a refetch.
  // Gated on `hydrated` so a live event can't race the initial load's own
  // `setChatEntries`. Requires `remittance_calculator_entries` in the
  // `supabase_realtime` publication (migration 145).
  useCalculatorEntriesRealtime({
    enabled: hydrated,
    onEntryEvent: (event) => {
      setChatEntries((prev) => applyCalculatorEntryRealtimeEvent(prev, event.eventType, event.new, event.old));
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
    setEditingEntryId(entry.id);
    setEditFacturado(entry.facturadoGyd == null ? "" : String(entry.facturadoGyd));
    setEditInvertido(entry.invertidoGyd == null ? "" : String(entry.invertidoGyd));
    setEntryActionMessage(null);
  }

  function closeEditor() {
    setEditingEntryId(null);
    setEditFacturado("");
    setEditInvertido("");
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
      const data = (await response.json()) as {
        entry: { id: string; facturadoGyd: number | null; invertidoGyd: number | null; retornoGyd: number | null; status: string };
      };
      setChatEntries((prev) =>
        prev.map((entry) =>
          entry.id === data.entry.id
            ? {
                ...entry,
                facturadoGyd: data.entry.facturadoGyd,
                invertidoGyd: data.entry.invertidoGyd,
                retornoGyd: data.entry.retornoGyd,
                status: data.entry.status as ChatCalculatorEntry["status"],
              }
            : entry,
        ),
      );
      setEntryActionMessage(null);
      closeEditor();
    } catch {
      setEntryActionMessage({ entryId, text: "No se pudo corregir la operación." });
    } finally {
      setEditSaving(false);
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

  function clearAll() {
    if (!window.confirm("¿Seguro que deseas borrar el registro de esta semana?")) return;
    // The global rates are DB-managed (calculator_rate_versions), shared
    // across weeks -- clearing this week's manual log must not touch them.
    setRawText("");
    setPeriodo("");
    localStorage.removeItem(STORAGE_KEYS.raw);
    localStorage.removeItem(STORAGE_KEYS.period);
  }

  function exportar() {
    const title = periodo || "Sin_Periodo";
    const automaticText = chatEntries.map((entry) => `• ${entry.customerName || "Sin nombre"} ${chatEntryAmountText(entry)} [${entry.status}]`).join("\n");
    const text = `=== CIERRE SEMANAL DE REMESAS ===\nPERIODO: ${periodo}\n--------------------------------\n\nTOTAL FACTURADO (GYD): ${formatNumber(totals.fact)}\nTOTAL INVERTIDO (GYD): ${formatNumber(totals.inv)}\nRETORNO NETO (GANANCIA): ${formatNumber(totals.ret)}\n\n=== REGISTRO MANUAL EN BRUTO ===\n${rawText}\n\n=== OPERACIONES DEL CHAT (SOLO LECTURA) ===\n${automaticText}`;
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    link.download = `Cierre_${title.replace(/\s/g, "_")}.txt`;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  return (
    <main className="legacyCalc">
      <div className="legacyContainer">
        <div className="legacyTopBar">
          <h1>📊 Cierre Semanal PRO</h1>
        </div>

        <details>
          <summary>❓ Guía Rápida de Formatos de Registro</summary>
          <table className="legacyHelpTable"><thead><tr><th>Servicio</th><th>Ejemplo</th><th>Cálculo</th></tr></thead><tbody>
            <tr><td><b>CUP</b></td><td><code>• Fran 50k CUP (235/980)</code></td><td>Tarifa global para venta; paréntesis para costo.</td></tr>
            <tr><td><b>Zelle / MLC / Clásica / Tropical</b></td><td><code>• Pedro 150 MLC (30%/240/245)</code><br /><code>• Julié 2.8k Zelle (3%/235/250)</code></td><td>Aplica % descuento (si hay) y costo/venta en GYD.</td></tr>
            <tr><td><b>USDT</b></td><td><code>• Carlos 1k usdt (235/260)</code></td><td>Costo y venta directos en GYD por USDT.</td></tr>
            <tr><td><b>Recargas Promo</b></td><td><code>• Josefa 1 rec promo (23.1/6.2k/242)</code></td><td><code>(USDT Costo / Venta GYD / Tasa USDT GYD)</code></td></tr>
            <tr><td><b>Saldo Móvil</b></td><td><code>• Carlos 2 saldo movil (1.25/1k/242.21)</code></td><td><code>(USDT Costo / Venta GYD / Tasa USDT GYD)</code></td></tr>
            <tr><td><b>Servicios Directos</b></td><td><code>• Iza 1 ext visa 5k GYD</code></td><td><b>Ganancia limpia:</b> Inv = 0, Retorno = Monto.</td></tr>
          </tbody></table>
        </details>

        <div className="legacyCard legacyFlex">
          <div><label htmlFor="periodo">Período / Semana</label><input id="periodo" placeholder="Ej. SEMANA 1 AGOSTO" value={periodo} onChange={(event) => setPeriodo(event.target.value)} /></div>
        </div>

        <div className="legacyCard">
          <h2>💱 Tarifas Globales</h2>
          <div className="legacyRateEditor" id="tarifasGlobales">
            <div>
              <label htmlFor="tasaSeleccionada">Tasa a cambiar</label>
              <select
                id="tasaSeleccionada"
                value={selectedRate}
                onChange={(event) => { setSelectedRate(event.target.value as RateKey); setRateDraft(null); setRatesMessage(null); }}
                disabled={ratesLocked || ratesSaving}
              >
                {RATE_FIELDS.map((field) => <option key={field.key} value={field.key}>{field.label}</option>)}
              </select>
            </div>
            <div>
              <label htmlFor="tasaValor">Nuevo valor</label>
              <input id="tasaValor" type="number" step="0.01" min="0" value={rateInputValue} onChange={(event) => setRateDraft(event.target.value)} disabled={ratesLocked || ratesSaving} />
            </div>
            <button type="button" id="actualizarTasa" onClick={() => void actualizarTasa()} disabled={ratesLocked || ratesSaving} style={{ width: "auto" }}>
              {ratesSaving ? "Actualizando…" : "Actualizar"}
            </button>
          </div>
          {ratesMessage && (
            <div id="tasasMensaje" className={ratesMessageKind === "ok" ? "legacyNotice" : "legacyError"} role="status">{ratesMessage}</div>
          )}
          <h3 className="legacyRatesTitle">Tasas actuales</h3>
          <dl className="legacyRateList" id="tasasActuales">
            {RATE_FIELDS.map((field) => {
              const value = rateValueOf(rates, field.key);
              return (
                <div className="legacyRateRow" key={field.key}>
                  <dt>{field.label}</dt>
                  <dd>{value == null ? "—" : String(value)}</dd>
                </div>
              );
            })}
          </dl>
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
            <h2 style={{ margin: 0 }}>📝 Registros de la Semana</h2>
            <button type="button" onClick={toggleFullscreen} style={{ width: "auto", padding: "6px 12px", fontSize: 13, minHeight: 36, background: fullscreen ? "#dc3545" : "var(--legacy-accent)" }}>{fullscreen ? "✕ Salir de Pantalla Completa" : "⛶ Maximizar"}</button>
          </div>
          <span className="legacySmall">Usa el botón <b>+ Viñeta</b> o escribe <code>-</code> + <code>Espacio</code>. Presiona <code>Enter</code> para nueva línea.</span>
          <textarea id="rawText" value={rawText} onChange={handleTextChange} onKeyDown={handleKeys} placeholder={'Miércoles 5\n• Fran 50k CUP (235/980)\n• Josefa 1 rec promo (23.1/6.2k/242)\n• Pedro 150 MLC (30%/240/245)\n• Carlos 2 saldo movil (1.25/1k/242.21)\n• Carlos 1k usdt (235/260)\n• Iza 1 ext visa 5k GYD'} />
          <button type="button" className="legacyBulletButton" onClick={insertManualBullet}>+ Viñeta •</button>
        </div>

        {saveError && <div className="legacyError">{saveError}</div>}

        <div className="legacyTotals">
          <div className="legacyTotalBox"><h3>💰 Facturado (GYD)</h3><p style={{ fontSize: "1.5em", fontWeight: "bold", margin: "5px 0" }}>{formatNumber(totals.fact)}</p></div>
          <div className="legacyTotalBox"><h3>🔁 Invertido (GYD)</h3><p style={{ fontSize: "1.5em", fontWeight: "bold", margin: "5px 0" }}>{formatNumber(totals.inv)}</p></div>
          <div className="legacyTotalBox"><h3>📈 Retorno Neto (GYD)</h3><p style={{ fontSize: "1.5em", fontWeight: "bold", color: "#28a745", margin: "5px 0" }}>{formatNumber(totals.ret)}</p></div>
        </div>

        <div className="legacyCard"><h2>⚙️ Desglose Semanal por Servicios</h2>{serviceTotals.map((service) => <div className="legacyCard" style={{ marginBottom: 10, padding: 12 }} key={service.name}><div className="legacyBlockRow"><b>Categoría: {service.name}</b><span>Fact: <b>{formatNumber(service.fact)} GYD</b> | Inv: <b>{formatNumber(service.inv)} GYD</b> | Retorno: <b style={{ color: "green" }}>{formatNumber(service.ret)} GYD</b></span></div></div>)}</div>

        <div className="legacyCard"><h2>🔍 Auditoría de Operaciones por Día</h2><div style={{ maxHeight: 400, overflowY: "auto" }}>{operationGroups.map((group) => <div key={group.day}><div className="legacyDayHeader">{group.day}</div><table className="legacyParsedTable"><thead><tr><th>Cliente</th><th>Monto</th><th>Tipo</th><th>Detalle</th><th>Fact. (GYD)</th><th>Inv. (GYD)</th><th>Ganancia</th></tr></thead><tbody>{group.operations.map((operation, index) => <tr key={`${group.day}-${index}`}>{isErrorLine(operation) ? <td colSpan={7} style={{ color: "orange" }}>⚠️ No interpretado: &quot;{operation.raw}&quot;</td> : <><td data-label="Cliente"><b>{operation.cliente}</b></td><td data-label="Monto">{operation.montoOrig}</td><td data-label="Tipo"><span className="legacyBadge">{operation.tipo}</span></td><td data-label="Detalle">{operation.detalle || "-"}</td><td data-label="Fact. (GYD)">{formatNumber(operation.fact)}</td><td data-label="Inv. (GYD)">{formatNumber(operation.inv)}</td><td data-label="Ganancia" style={{ color: "green", fontWeight: "bold" }}>{formatNumber(operation.retorno)}</td></>}</tr>)}</tbody></table></div>)}</div></div>

        <div className="legacyCard">
          <h2>🔗 Operaciones del chat</h2>
          {chatEntries.length === 0 ? (
            <span className="legacySmall">No hay operaciones vinculadas.</span>
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
                    const editPreview = (Number(editFacturado) || 0) - (Number(editInvertido) || 0);
                    return (
                      <tr key={entry.id}>
                        <td data-label="Fecha">{entry.entryDate.slice(0, 10)}</td>
                        <td data-label="Cliente"><b>{entry.customerName || "—"}</b></td>
                        <td data-label="Monto">{chatEntryAmountText(entry)}</td>
                        <td data-label="Tipo"><span className="legacyBadge">{ledgerServiceLabel(entry.service)}</span></td>
                        <td data-label="Estado">{entry.status === "completed" ? "Completada" : `Pendiente${entry.missingRates.length ? `: ${pendingReason(entry)}` : ""}`}</td>
                        <td data-label="Fact. (GYD)">
                          {editing ? (
                            <input
                              id={`editFacturado-${entry.id}`}
                              type="number"
                              step="0.01"
                              value={editFacturado}
                              onChange={(event) => setEditFacturado(event.target.value)}
                            />
                          ) : entry.facturadoGyd == null ? "—" : formatNumber(entry.facturadoGyd)}
                        </td>
                        <td data-label="Inv. (GYD)">
                          {editing ? (
                            <input
                              id={`editInvertido-${entry.id}`}
                              type="number"
                              step="0.01"
                              value={editInvertido}
                              onChange={(event) => setEditInvertido(event.target.value)}
                            />
                          ) : entry.invertidoGyd == null ? "—" : formatNumber(entry.invertidoGyd)}
                        </td>
                        <td data-label="Ganancia">
                          {editing ? formatNumber(editPreview) : entry.retornoGyd == null ? "—" : formatNumber(entry.retornoGyd)}
                        </td>
                        <td data-label="Acciones" className="legacyActionsCell">
                          {entry.status === "completed" && (
                            editing ? (
                              <div style={{ display: "flex", gap: 6, flexDirection: "column" }}>
                                <div style={{ display: "flex", gap: 6 }}>
                                  <button
                                    type="button"
                                    id={`guardarEntry-${entry.id}`}
                                    onClick={() => void saveEditEntry(entry.id)}
                                    disabled={editSaving}
                                    style={{ width: "auto" }}
                                  >
                                    {editSaving ? "Guardando…" : "Guardar"}
                                  </button>
                                  <button
                                    type="button"
                                    id={`cancelarEntry-${entry.id}`}
                                    className="legacySecondary"
                                    onClick={cancelEditEntry}
                                    disabled={editSaving}
                                    style={{ width: "auto" }}
                                  >
                                    Cancelar
                                  </button>
                                </div>
                                {rowMessage && <div className="legacyError">{rowMessage}</div>}
                              </div>
                            ) : (
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
                            )
                          )}
                          {!editing && rowMessage && <div className="legacyError">{rowMessage}</div>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>

        <div className="legacyCard legacyFlex"><button type="button" onClick={exportar}>📄 Exportar Reporte (.txt)</button><button type="button" className="legacySecondary" onClick={clearAll}>🧹 Limpiar Todo</button></div>
      </div>
    </main>
  );
}
