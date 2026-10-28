"use client";

import { useEffect, useState } from "react";
import { ServiceDot } from "@/components/service/service-dot";
import { chatEntryAmountText, ledgerServiceLabel } from "@/lib/calculator/entry-display";
import type { CalculatorWeek, CalculatorWeekSummary } from "@/lib/calculator/weeks";
import { moneyCellProps, profitTone } from "@/lib/money-tone";
import { cutDate, formatNumber, TotalBox } from "./legacy-calc-format";
import "./calculadora.module.css";

/**
 * The archived weeks ("Semanas anteriores"): every "Limpiar Todo" cut of the Semana tab, read only. It reads the list
 * each time it becomes active (the tab stays mounted while hidden), so a cut made in the Semana tab shows up as soon
 * as the Cierres tab opens again.
 */
export function ArchivedWeeks({ active = true }: { active?: boolean }) {
  const [weeks, setWeeks] = useState<CalculatorWeekSummary[]>([]);
  const [openWeek, setOpenWeek] = useState<CalculatorWeek | null>(null);
  const [weekMessage, setWeekMessage] = useState<string | null>(null);

  // A failure here is non-fatal: the list just stays empty.
  useEffect(() => {
    if (!active) return;
    let current = true;
    void (async () => {
      try {
        const response = await fetch("/api/calculadora/weeks", { cache: "no-store" });
        if (!response.ok) return;
        const data = (await response.json()) as { weeks?: CalculatorWeekSummary[] };
        if (current) setWeeks(data.weeks ?? []);
      } catch {
        /* keep what is shown */
      }
    })();
    return () => { current = false; };
  }, [active]);

  async function openArchivedWeek(weekId: string) {
    setWeekMessage(null);
    try {
      const response = await fetch(`/api/calculadora/weeks/${weekId}`, { cache: "no-store" });
      if (!response.ok) throw new Error("week read failed");
      const data = (await response.json()) as { week: CalculatorWeek };
      setOpenWeek(data.week);
    } catch {
      setWeekMessage("No se pudo abrir la semana.");
    }
  }

  return (
    <div className="legacyCalc legacyEmbedded">
      {/* Open here: in the Cierres tab the list is the main content. */}
      <details id="semanasAnteriores" open>
        <summary>Semanas anteriores{weeks.length > 0 ? ` (${weeks.length})` : ""}</summary>
        <span className="legacySmall">Cada «Limpiar Todo» guarda la semana aquí, solo para consultarla. Sus operaciones siguen contando en Finanzas y en el panel.</span>
        {weekMessage && <div className="legacyError">{weekMessage}</div>}
        {weeks.length === 0 ? (
          <span className="legacySmall">Aún no hay semanas archivadas.</span>
        ) : (
          <table className="legacyParsedTable">
            <thead><tr><th>Corte</th><th>Período</th><th>Fact. (GYD)</th><th>Inv. (GYD)</th><th>Ganancia</th><th className="legacyActionsCell"></th></tr></thead>
            <tbody>
              {weeks.map((week) => (
                <tr key={week.id}>
                  <td data-label="Corte">{cutDate(week.cutAt)}</td>
                  <td data-label="Período"><b>{week.periodo || "Sin período"}</b></td>
                  <td data-label="Fact. (GYD)" {...moneyCellProps("in")}>{formatNumber(week.manualTotals.facturadoGyd + week.chatTotals.facturadoGyd)}</td>
                  <td data-label="Inv. (GYD)" {...moneyCellProps("out")}>{formatNumber(week.manualTotals.invertidoGyd + week.chatTotals.invertidoGyd)}</td>
                  <td data-label="Ganancia" {...moneyCellProps(profitTone(week.manualTotals.retornoGyd + week.chatTotals.retornoGyd))}>{formatNumber(week.manualTotals.retornoGyd + week.chatTotals.retornoGyd)}</td>
                  <td className="legacyActionsCell">
                    <button type="button" id={`verSemana-${week.id}`} className="legacySecondary" onClick={() => void openArchivedWeek(week.id)} style={{ width: "auto" }}>Ver</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

      {openWeek && (
        <div className="legacyCard" id="semanaArchivada">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, marginBottom: 10 }}>
            <h2 style={{ margin: 0 }}>Semana archivada: {openWeek.periodo || "Sin período"} (corte {cutDate(openWeek.cutAt)})</h2>
            <button type="button" id="cerrarSemana" className="legacySecondary" onClick={() => setOpenWeek(null)} style={{ width: "auto" }}>Cerrar</button>
          </div>
          <span className="legacySmall">Solo lectura.</span>
          <div className="legacyTotals">
            <TotalBox title="Facturado (GYD)" kind="in" value={openWeek.manualTotals.facturadoGyd + openWeek.chatTotals.facturadoGyd} />
            <TotalBox title="Invertido (GYD)" kind="out" value={openWeek.manualTotals.invertidoGyd + openWeek.chatTotals.invertidoGyd} />
            <TotalBox title="Retorno Neto (GYD)" kind="result" value={openWeek.manualTotals.retornoGyd + openWeek.chatTotals.retornoGyd} />
          </div>
          <span className="legacySmall">Registro manual: Fact {formatNumber(openWeek.manualTotals.facturadoGyd)} | Inv {formatNumber(openWeek.manualTotals.invertidoGyd)} | Retorno {formatNumber(openWeek.manualTotals.retornoGyd)}. Operaciones del chat: Fact {formatNumber(openWeek.chatTotals.facturadoGyd)} | Inv {formatNumber(openWeek.chatTotals.invertidoGyd)} | Retorno {formatNumber(openWeek.chatTotals.retornoGyd)}.</span>
          <h3>Registro manual</h3>
          <pre style={{ whiteSpace: "pre-wrap", fontFamily: "monospace", margin: 0 }}>{openWeek.rawText}</pre>
          <h3>Operaciones</h3>
          {openWeek.entries.length === 0 ? (
            <span className="legacySmall">Esta semana no tuvo operaciones.</span>
          ) : (
            <div style={{ maxHeight: 400, overflowY: "auto" }}>
              <table className="legacyParsedTable">
                <thead><tr><th>Fecha</th><th>Cliente</th><th>Monto</th><th>Tipo</th><th>Fact. (GYD)</th><th>Inv. (GYD)</th><th>Ganancia</th></tr></thead>
                <tbody>
                  {openWeek.entries.map((entry) => (
                    <tr key={entry.id}>
                      <td data-label="Fecha">{entry.entryDate.slice(0, 10)}</td>
                      <td data-label="Cliente"><b>{entry.customerName || "—"}</b></td>
                      <td data-label="Monto">{chatEntryAmountText(entry)}</td>
                      <td data-label="Tipo"><span className="legacyBadge"><ServiceDot service={entry.service} />{ledgerServiceLabel(entry.service)}</span>{entry.source === "manual" && <span className="legacyBadge" title="Registrada a mano" style={{ marginLeft: 6 }}>Manual</span>}</td>
                      <td data-label="Fact. (GYD)" {...moneyCellProps(entry.facturadoGyd == null ? "neutral" : "in")}>{entry.facturadoGyd == null ? "—" : formatNumber(entry.facturadoGyd)}</td>
                      <td data-label="Inv. (GYD)" {...moneyCellProps(entry.invertidoGyd == null ? "neutral" : "out")}>{entry.invertidoGyd == null ? "—" : formatNumber(entry.invertidoGyd)}</td>
                      <td data-label="Ganancia" {...moneyCellProps(profitTone(entry.retornoGyd))}>{entry.retornoGyd == null ? "—" : formatNumber(entry.retornoGyd)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
      </details>
    </div>
  );
}
