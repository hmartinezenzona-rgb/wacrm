-- Rollback of 270: production had no grant on cerebro_config for service_role.
REVOKE SELECT, INSERT, UPDATE ON TABLE public.cerebro_config FROM service_role;
