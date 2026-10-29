"use client";

import { ServiceDot } from "@/components/service/service-dot";
import { chatEntryAmountText, ledgerServiceLabel } from "@/lib/calculator/entry-display";
import type { CalculatorWeek } from "@/lib/calculator/weeks";
import { moneyCellProps, profitTone } from "@/lib/money-tone";
import { cutDate, formatNumber, TotalBox } from "./legacy-calc-format";
import "./calculadora.module.css";

/**
 * One archived week, read only: its typed text, totals and every entry. It is what "Ver los registros" opens in the
 * Cierres tab; the list and the figures around it live in `cierres-overview.tsx`.
 */
export function ArchivedWeekDetail({ week: openWeek, onClose }: { week: CalculatorWeek; onClose: () => void }) {
  return (
    <div className="legacyCalc legacyEmbedded">
      <div className="legacyCard" id="semanaArchivada">
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, marginBottom: 10 }}>
          <h2 style={{ margin: 0 }}>Semana archivada: {openWeek.periodo || "Sin período"} (corte {cutDate(openWeek.cutAt)})</h2>
          <button type="button" id="cerrarSemana" className="legacySecondary" onClick={onClose} style={{ width: "auto" }}>Cerrar</button>
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
    </div>
  );
}
