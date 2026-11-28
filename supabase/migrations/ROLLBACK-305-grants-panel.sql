-- ROLLBACK 305: removes the SELECT grants added for the panel.

REVOKE SELECT ON TABLE public.session_events FROM service_role;
REVOKE SELECT ON TABLE public.promo_etecsa FROM service_role;
REVOKE SELECT ON TABLE public.precio_recarga FROM service_role;
