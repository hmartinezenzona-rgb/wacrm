"use client";

import { useEffect, useMemo, useState, type ChangeEvent, type KeyboardEvent } from "react";
import { procesarTexto, type WebCalculatorErrorLine, type WebCalculatorParsedLine } from "@/lib/calculator/web-calculator";
import "./calculadora.module.css";

const DEFAULT_TARIFF = "3.0";
const STORAGE_KEYS = {
  raw: "remesas_rawText",
  period: "remesas_periodo",
  tariff: "remesas_tarifa",
  buyUsdtGyd: "remesas_compraUsdtGyd",
  sellUsdtGyd: "remesas_ventaUsdtGyd",
  sellUsdtCup: "remesas_ventaUsdtCup",
} as const;

function toRateOrNull(value: string): number | null {
  if (value.trim() === "") return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : null;
}

function isErrorLine(operation: WebCalculatorParsedLine): operation is WebCalculatorErrorLine {
  return "error" in operation;
}

function formatNumber(value: number): string {
  return value.toFixed(2);
}

type ChatCalculatorEntry = {
  id: string;
  operationId: string;
  status: "completed" | "verified_pending";
  service: string;
  customerName: string | null;
  amount: number;
  amountCurrency: string;
  entryDate: string;
  facturadoGyd: number | null;
  invertidoGyd: number | null;
  retornoGyd: number | null;
  missingRates: string[];
};

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

export default function CalculadoraPage() {
  const [rawText, setRawText] = useState("");
  const [periodo, setPeriodo] = useState("");
  const [tarifa, setTarifa] = useState(DEFAULT_TARIFF);
  const [compraUsdtGyd, setCompraUsdtGyd] = useState("");
  const [ventaUsdtGyd, setVentaUsdtGyd] = useState("");
  const [ventaUsdtCup, setVentaUsdtCup] = useState("");
  const [chatEntries, setChatEntries] = useState<ChatCalculatorEntry[]>([]);
  const [dark, setDark] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

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
      const current = byService.get(entry.service) ?? { name: entry.service, fact: 0, inv: 0, ret: 0 };
      current.fact += entry.facturadoGyd ?? 0;
      current.inv += entry.invertidoGyd ?? 0;
      current.ret += entry.retornoGyd ?? 0;
      byService.set(entry.service, current);
    }
    return [...byService.values()];
  }, [chatEntries, parsed.services]);

  useEffect(() => {
    let active = true;
    void fetch(`/api/calculadora?t=${Date.now()}`, { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) throw new Error("calculator document read failed");
        return response.json() as Promise<{
          rawText?: string;
          periodo?: string;
          tarifa?: number;
          compraUsdtGyd?: number | null;
          ventaUsdtGyd?: number | null;
          ventaUsdtCup?: number | null;
          chatOperations?: { entries?: ChatCalculatorEntry[] };
        }>;
      })
      .then((data) => {
        if (!active) return;
        setRawText(data.rawText ?? "");
        setPeriodo(data.periodo ?? "");
        setTarifa(String(data.tarifa ?? DEFAULT_TARIFF));
        setCompraUsdtGyd(data.compraUsdtGyd == null ? "" : String(data.compraUsdtGyd));
        setVentaUsdtGyd(data.ventaUsdtGyd == null ? "" : String(data.ventaUsdtGyd));
        setVentaUsdtCup(data.ventaUsdtCup == null ? "" : String(data.ventaUsdtCup));
        setChatEntries(data.chatOperations?.entries ?? []);
        localStorage.setItem(STORAGE_KEYS.raw, data.rawText ?? "");
        localStorage.setItem(STORAGE_KEYS.period, data.periodo ?? "");
        localStorage.setItem(STORAGE_KEYS.tariff, String(data.tarifa ?? DEFAULT_TARIFF));
        localStorage.setItem(STORAGE_KEYS.buyUsdtGyd, data.compraUsdtGyd == null ? "" : String(data.compraUsdtGyd));
        localStorage.setItem(STORAGE_KEYS.sellUsdtGyd, data.ventaUsdtGyd == null ? "" : String(data.ventaUsdtGyd));
        localStorage.setItem(STORAGE_KEYS.sellUsdtCup, data.ventaUsdtCup == null ? "" : String(data.ventaUsdtCup));
      })
      .catch(() => {
        if (!active) return;
        setRawText(localStorage.getItem(STORAGE_KEYS.raw) ?? "");
        setPeriodo(localStorage.getItem(STORAGE_KEYS.period) ?? "");
        setTarifa(localStorage.getItem(STORAGE_KEYS.tariff) || DEFAULT_TARIFF);
        setCompraUsdtGyd(localStorage.getItem(STORAGE_KEYS.buyUsdtGyd) ?? "");
        setVentaUsdtGyd(localStorage.getItem(STORAGE_KEYS.sellUsdtGyd) ?? "");
        setVentaUsdtCup(localStorage.getItem(STORAGE_KEYS.sellUsdtCup) ?? "");
        setChatEntries([]);
      })
      .finally(() => { if (active) setHydrated(true); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!hydrated) return;
    localStorage.setItem(STORAGE_KEYS.raw, rawText);
    localStorage.setItem(STORAGE_KEYS.period, periodo);
    localStorage.setItem(STORAGE_KEYS.tariff, tarifa);
    localStorage.setItem(STORAGE_KEYS.buyUsdtGyd, compraUsdtGyd);
    localStorage.setItem(STORAGE_KEYS.sellUsdtGyd, ventaUsdtGyd);
    localStorage.setItem(STORAGE_KEYS.sellUsdtCup, ventaUsdtCup);
    const timer = window.setTimeout(() => {
      void fetch("/api/calculadora", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          rawText,
          periodo,
          tarifa: Number(tarifa),
          compraUsdtGyd: toRateOrNull(compraUsdtGyd),
          ventaUsdtGyd: toRateOrNull(ventaUsdtGyd),
          ventaUsdtCup: toRateOrNull(ventaUsdtCup),
        }),
      }).then((response) => {
        if (!response.ok) throw new Error("calculator document save failed");
        setSaveError(null);
      }).catch(() => setSaveError("No se pudo guardar en el servidor; los datos siguen guardados localmente."));
    }, 600);
    return () => window.clearTimeout(timer);
  }, [hydrated, rawText, periodo, tarifa, compraUsdtGyd, ventaUsdtGyd, ventaUsdtCup]);

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
    setRawText("");
    setPeriodo("");
    setTarifa(DEFAULT_TARIFF);
    setCompraUsdtGyd("");
    setVentaUsdtGyd("");
    setVentaUsdtCup("");
    localStorage.removeItem(STORAGE_KEYS.raw);
    localStorage.removeItem(STORAGE_KEYS.period);
    localStorage.removeItem(STORAGE_KEYS.tariff);
    localStorage.removeItem(STORAGE_KEYS.buyUsdtGyd);
    localStorage.removeItem(STORAGE_KEYS.sellUsdtGyd);
    localStorage.removeItem(STORAGE_KEYS.sellUsdtCup);
  }

  function exportar() {
    const title = periodo || "Sin_Periodo";
    const automaticText = chatEntries.map((entry) => `• ${entry.customerName || "Sin nombre"} ${entry.amount} ${entry.service} [${entry.status}]`).join("\n");
    const text = `=== CIERRE SEMANAL DE REMESAS ===\nPERIODO: ${periodo}\n--------------------------------\n\nTOTAL FACTURADO (GYD): ${formatNumber(totals.fact)}\nTOTAL INVERTIDO (GYD): ${formatNumber(totals.inv)}\nRETORNO NETO (GANANCIA): ${formatNumber(totals.ret)}\n\n=== REGISTRO MANUAL EN BRUTO ===\n${rawText}\n\n=== OPERACIONES DEL CHAT (SOLO LECTURA) ===\n${automaticText}`;
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    link.download = `Cierre_${title.replace(/\s/g, "_")}.txt`;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  return (
    <main className={`legacyCalc${dark ? " dark" : ""}`}>
      <div className="legacyContainer">
        <div className="legacyTopBar">
          <h1>📊 Cierre Semanal PRO</h1>
          <button type="button" onClick={() => setDark((value) => !value)} style={{ width: "auto", margin: 0 }}>🌗 Tema</button>
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
          <div className="legacyFlex">
            <div><label htmlFor="tarifaCupGlobal">Tarifa CUP global</label><input id="tarifaCupGlobal" type="number" step="0.1" value={tarifa} onChange={(event) => setTarifa(event.target.value)} /></div>
            <div><label htmlFor="compraUsdtGyd">Compra USDT (GYD)</label><input id="compraUsdtGyd" type="number" step="0.01" value={compraUsdtGyd} onChange={(event) => setCompraUsdtGyd(event.target.value)} /></div>
            <div><label htmlFor="ventaUsdtGyd">Venta USDT/Zelle (GYD)</label><input id="ventaUsdtGyd" type="number" step="0.01" value={ventaUsdtGyd} onChange={(event) => setVentaUsdtGyd(event.target.value)} /></div>
            <div><label htmlFor="ventaUsdtCup">Venta USDT (CUP)</label><input id="ventaUsdtCup" type="number" step="0.01" value={ventaUsdtCup} onChange={(event) => setVentaUsdtCup(event.target.value)} /></div>
          </div>
        </div>

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

        <div className="legacyCard"><h2>🔗 Operaciones del chat (solo lectura)</h2>{chatEntries.length === 0 ? <span className="legacySmall">No hay operaciones vinculadas.</span> : <div style={{ maxHeight: 400, overflowY: "auto" }}><table className="legacyParsedTable"><thead><tr><th>Fecha</th><th>Cliente</th><th>Monto</th><th>Tipo</th><th>Estado</th><th>Fact. (GYD)</th><th>Inv. (GYD)</th><th>Ganancia</th></tr></thead><tbody>{chatEntries.map((entry) => <tr key={entry.id}><td data-label="Fecha">{entry.entryDate.slice(0, 10)}</td><td data-label="Cliente"><b>{entry.customerName || "—"}</b></td><td data-label="Monto">{entry.amount} {entry.service}</td><td data-label="Tipo"><span className="legacyBadge">{entry.service}</span></td><td data-label="Estado">{entry.status === "completed" ? "Completada" : `Pendiente${entry.missingRates.length ? `: ${entry.missingRates.join(", ")}` : ""}`}</td><td data-label="Fact. (GYD)">{entry.facturadoGyd == null ? "—" : formatNumber(entry.facturadoGyd)}</td><td data-label="Inv. (GYD)">{entry.invertidoGyd == null ? "—" : formatNumber(entry.invertidoGyd)}</td><td data-label="Ganancia">{entry.retornoGyd == null ? "—" : formatNumber(entry.retornoGyd)}</td></tr>)}</tbody></table></div>}</div>

        <div className="legacyCard legacyFlex"><button type="button" onClick={exportar}>📄 Exportar Reporte (.txt)</button><button type="button" className="legacySecondary" onClick={clearAll}>🧹 Limpiar Todo</button></div>
      </div>
    </main>
  );
}
