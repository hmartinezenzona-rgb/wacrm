/**
 * What the history table shows in its "Destino" column. Only remittances
 * carry a beneficiary; `cerebro_dashboard_historial` (088) returns just the
 * name and the already-masked card, so a Zelle or Clásica beneficiary shows
 * its name alone and a service without one (recargas, …) shows a dash.
 */
export function historialDestino(row: { beneficiario: string | null; tarjeta: string | null }): string {
  const parts = [row.beneficiario, row.tarjeta].map((part) => part?.trim() ?? "").filter(Boolean);
  return parts.length ? parts.join(" · ") : "—";
}
