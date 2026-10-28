-- Rollback of 350: back to production's previous state (service key can read promo_etecsa, not change it).
-- Staging's old table-level UPDATE is not restored on purpose: production never had it.
REVOKE UPDATE (estado, confirmada_at, confirmada_por) ON TABLE public.promo_etecsa FROM service_role;
