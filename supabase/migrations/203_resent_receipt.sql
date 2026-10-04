-- =====================================================================
-- 203 — A receipt sent again in another photo is the same payment (staging first)
--
-- odd/tasks/remesa-closing-and-cash.md (C). Production, Bruce 2026-10-02: his 29,000 GYD receipt (14:16, verified) was
-- sent again in another photo; vision read 28,000 GYD, another reference and the year 2023. The image hash differed,
-- so the hash dedup ('Dedup comprobantes') let it through and it opened a second remesa (incident, sin_correo) that the
-- owner had to delete.
-- cerebro_comprobante_reenviado(phone, date, amount, ref) -> the comp_id of the ORIGINAL receipt when the same customer
-- (last 10 digits of the phone) has, in the last 48 h, a receipt of a live (not cancelled) operation with the same
-- month-day hour:minute (any year: the year is what gets misread) and an amount within 10%. The Cerebro's dedup marks
-- such a receipt as a duplicate of the original (gate97), so nothing is registered twice and the bot answers from the
-- original remesa's state, as it already does for the same image sent twice.
--
-- Guarded by supabase/staging/assertions/resent-receipt.sql.
-- ROLLBACK: ROLLBACK-203-resent-receipt.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_comprobante_reenviado(p_telefono text, p_fecha text, p_monto numeric, p_ref text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT r.comp_id
    FROM remittance_operation_receipts r
    JOIN remittance_operations o ON o.id = r.operation_id
    JOIN conversations v ON v.id = o.conversation_id
    JOIN contacts c ON c.id = v.contact_id
   WHERE substr(coalesce(p_fecha, ''), 6, 11) ~ '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'
     AND p_monto > 0
     AND length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) >= 7
     AND right(regexp_replace(c.phone, '\D', '', 'g'), 10) = right(regexp_replace(p_telefono, '\D', '', 'g'), 10)
     AND r.created_at > now() - interval '48 hours'
     AND r.comp_id IS NOT NULL
     AND o.status <> 'cancelled'
     AND substr(r.receipt_date, 6, 11) = substr(p_fecha, 6, 11)
     AND abs(r.amount - p_monto) <= 0.10 * r.amount
   ORDER BY r.created_at DESC
   LIMIT 1;
$function$;
REVOKE ALL ON FUNCTION public.cerebro_comprobante_reenviado(text, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_comprobante_reenviado(text, text, numeric, text) TO service_role;
