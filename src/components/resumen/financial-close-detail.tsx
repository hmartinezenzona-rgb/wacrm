"use client";

import { useTranslations } from "next-intl";
import type { CloseEntry, ExcludedEntry, FinancialClose } from "@/lib/financial-close/read-model";
import { ledgerServiceLabel } from "@/lib/calculator/entry-display";
import { fmtAmount, fmtGyd, guyanaTime, rateLabel, shortId } from "./financial-close-format";

const DELIVERY_KEYS = ["proof_sent", "no_proof", "skip_proof"] as const;

/** Every ledger entry behind the totals, then the voided and rate-pending
 *  ones that never count — the part of the close someone audits line by line. */
export function FinancialCloseDetail({ close }: { close: FinancialClose }) {
  const t = useTranslations("Resumen.cierre");

  const delivery = (mode: string | null) =>
    mode && (DELIVERY_KEYS as readonly string[]).includes(mode) ? t(`entrega.${mode}`) : (mode ?? "—");

  const commonCells = (e: CloseEntry) => (
    <>
      <td className="whitespace-nowrap px-2 py-1.5">{e.day}</td>
      <td className="whitespace-nowrap px-2 py-1.5">{guyanaTime(e.completedAt)}</td>
      <td className="px-2 py-1.5 font-mono text-xs" title={e.operationId ?? undefined}>
        {shortId(e.operationId)}
      </td>
      <td className="px-2 py-1.5">
        {e.customerName ?? "—"}
        {e.source === "manual" && (
          <span
            data-testid="manual-badge"
            title={t("manualHint")}
            className="ml-1.5 rounded border border-border bg-muted px-1 py-0.5 align-middle text-[10px] font-medium uppercase text-muted-foreground"
          >
            {t("manual")}
          </span>
        )}
      </td>
      <td className="px-2 py-1.5">{ledgerServiceLabel(e.service)}</td>
      <td className="whitespace-nowrap px-2 py-1.5 text-right">{fmtAmount(e.amount, e.amountCurrency)}</td>
      <td className="whitespace-nowrap px-2 py-1.5" title={e.rateVersionId ?? undefined}>
        {rateLabel(e)}
      </td>
      <td className="whitespace-nowrap px-2 py-1.5 text-right">{fmtGyd(e.facturadoGyd)}</td>
      <td className="whitespace-nowrap px-2 py-1.5 text-right">{fmtGyd(e.invertidoGyd)}</td>
      <td className="whitespace-nowrap px-2 py-1.5 text-right">{fmtGyd(e.retornoGyd)}</td>
    </>
  );

  const head = (extra: string[]) => (
    <thead>
      <tr className="text-left text-xs text-muted-foreground">
        {[
          t("cols.dia"),
          t("cols.hora"),
          t("cols.operacion"),
          t("cols.cliente"),
          t("cols.servicio"),
          t("cols.monto"),
          t("cols.tasa"),
          t("cols.facturado"),
          t("cols.invertido"),
          t("cols.retorno"),
          ...extra,
        ].map((label) => (
          <th key={label} className="whitespace-nowrap px-2 py-1.5 font-medium">
            {label}
          </th>
        ))}
      </tr>
    </thead>
  );

  return (
    <div className="space-y-3">
      {close.detail.length > 0 && (
        <section className="rounded-xl border border-border bg-card p-4">
          <h3 className="mb-2 text-sm font-semibold text-foreground">
            {t("detalle")} ({close.detail.length})
          </h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm tabular-nums">
              {head([t("cols.entrega"), t("cols.entregadoPor")])}
              <tbody>
                {close.detail.map((e) => (
                  <tr key={e.id} data-testid="detail-row" className="border-t border-border">
                    {commonCells(e)}
                    <td className="whitespace-nowrap px-2 py-1.5">{delivery(e.deliveryMode)}</td>
                    <td className="whitespace-nowrap px-2 py-1.5">{e.actorName ?? "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {close.excluded.length > 0 && (
        <section className="rounded-xl border border-dashed border-border bg-card p-4">
          <h3 className="mb-2 text-sm font-semibold text-muted-foreground">
            {t("excluidas")} ({close.excluded.length})
          </h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm tabular-nums text-muted-foreground">
              {head([t("cols.estado"), t("cols.motivo")])}
              <tbody>
                {close.excluded.map((e: ExcludedEntry) => (
                  <tr key={e.id} data-testid="excluded-row" className="border-t border-border">
                    {commonCells(e)}
                    <td className="whitespace-nowrap px-2 py-1.5">{t(`estado.${e.status}`)}</td>
                    <td className="px-2 py-1.5">
                      {e.status === "void" ? (e.voidReason ?? "—") : e.missingInputs.join(", ") || "—"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}
