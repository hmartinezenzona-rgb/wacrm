"use client";

import { useTranslations } from "next-intl";
import type { CloseEntry, FinancialClose } from "@/lib/financial-close/read-model";
import { moneyCellProps, profitTone } from "@/lib/money-tone";
import { useServiceName } from "@/hooks/use-service-name";
import { ServiceDot } from "@/components/service/service-dot";
import { fmtAmount, fmtGyd, guyanaTime, rateLabel, shortId } from "./financial-close-format";

const BASE_MONEY_CELL = "whitespace-nowrap px-2 py-1.5 text-right";
const DELIVERY_KEYS = ["proof_sent", "no_proof", "skip_proof"] as const;

/** Every ledger entry behind the totals — the part of the close someone audits line by line. The voided and
 *  rate-pending ones that never count are not listed here; they stay in the RPC and in the CSV export. */
export function FinancialCloseDetail({ close }: { close: FinancialClose }) {
  const t = useTranslations("Resumen.cierre");
  const serviceName = useServiceName();

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
      <td className="px-2 py-1.5">
        <ServiceDot service={e.service} />
        {serviceName(e.service)}
      </td>
      <td className="whitespace-nowrap px-2 py-1.5 text-right">{fmtAmount(e.amount, e.amountCurrency)}</td>
      <td className="whitespace-nowrap px-2 py-1.5" title={e.rateVersionId ?? undefined}>
        {rateLabel(e)}
      </td>
      <td {...moneyCellProps("in", BASE_MONEY_CELL)}>{fmtGyd(e.facturadoGyd)}</td>
      <td {...moneyCellProps("out", BASE_MONEY_CELL)}>{fmtGyd(e.invertidoGyd)}</td>
      <td {...moneyCellProps(profitTone(e.retornoGyd), BASE_MONEY_CELL)}>{fmtGyd(e.retornoGyd)}</td>
    </>
  );

  const head = () => (
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
          t("cols.entrega"),
          t("cols.entregadoPor"),
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
              {head()}
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
    </div>
  );
}
