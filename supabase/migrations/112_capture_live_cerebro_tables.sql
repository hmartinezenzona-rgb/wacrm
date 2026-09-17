-- =====================================================================
-- 112 — Capture the live, unversioned cerebro_* tables as a baseline
--
-- Same debt class 109 resolved for functions, now for tables. Three
-- `cerebro_*` tables run live on staging and production but have NO
-- `CREATE TABLE` anywhere in this repo's migration history — they were
-- created directly on the database rather than through a migration file:
--
--   1. cerebro_objetivo_envio (7 columns) — the partial-payment target
--      tracker. Read by cerebro_saldo_envio and written by
--      cerebro_objetivo_atar / cerebro_objetivo_cerrar (all three
--      versioned in 109) and by cerebro_fijar_objetivo (still
--      unversioned — it writes this table but is out of this migration's
--      scope, which is tables, not functions).
--
--   2. cerebro_revendedores (5 columns) — the reseller list joined by
--      cerebro_es_revendedor (versioned in 109).
--
--   3. cerebro_servicios (8 columns) — see THE LATENT BUG below.
--
-- This migration changes NO structure. Every column, type, default,
-- constraint and index below is copied from the live catalog on staging
-- (pg_attribute / pg_attrdef / pg_constraint / pg_indexes — see this
-- task's report for the raw queries and output). Applied to any
-- environment that already has these three tables (staging, production),
-- `CREATE TABLE IF NOT EXISTS` is a plain no-op: Postgres does not compare
-- the existing table against the given definition at all, it just sees the
-- name is taken and skips the whole statement. Its only purpose is to give
-- this repository — and a freshly-built database — a real, versioned
-- starting point, exactly as 109 did for the seven functions.
--
-- ---------------------------------------------------------------------
-- THE LATENT BUG — why this migration exists at all
-- ---------------------------------------------------------------------
--
-- `049_promo_proxima.sql` (line 86) reads `FROM cerebro_servicios s`, and
-- `054_visa_pasos_y_rebajas.sql` (lines 30, 37, 54) runs three
-- `UPDATE cerebro_servicios SET ...` statements. Neither migration —
-- nor any migration before them — ever creates `cerebro_servicios`. On
-- staging and production this is invisible, because the table has existed
-- there since before either migration ran. But on a database built from
-- this repo's migration history ALONE, from scratch, 054 fails outright
-- with `relation "cerebro_servicios" does not exist` (verified live — see
-- this task's report, step 4). 049 would fail the same way if it ran
-- first. This migration fixes that: after 112 runs, cerebro_servicios
-- exists before 049 and 054 ever touch it, on ANY database, not just the
-- two that happened to be bootstrapped by hand.
--
-- ---------------------------------------------------------------------
-- DELIBERATELY NOT CAPTURED HERE
-- ---------------------------------------------------------------------
--
-- Three more tables are live and equally unversioned in this repo:
-- `cerebro_memoria_respaldo_dsml`, `cerebro_semantic_turn_audit` and
-- `cerebro_telemetria_turno`. They are NOT captured here. Nothing in this
-- repository's migrations or `src/` references any of the three — they
-- belong to the separate "cerebro" migration series that lives in n8n's
-- own repository, which already has its own numbered migrations and its
-- own ownership of that series. Versioning them here would duplicate
-- ownership of the same tables across two repositories that already
-- collide on migration numbers; the omission is a decision, not an
-- oversight.
--
-- ---------------------------------------------------------------------
-- PRIVILEGES AND ROW LEVEL SECURITY — see the section near the end of
-- this file for why the RLS/GRANT statements are required even though
-- this is a byte-identical structural capture.
-- ---------------------------------------------------------------------

-- cerebro_objetivo_envio — one open target per conversation (the PK is
-- conversation_id itself, not a surrogate id): the amount a partial-payment
-- remittance must reach, what deal it is currently tied to, and when it
-- closed. No repo origin: never versioned before this migration.
CREATE TABLE IF NOT EXISTS public.cerebro_objetivo_envio (
  conversation_id uuid NOT NULL,
  monto           numeric NOT NULL,
  moneda          text NOT NULL DEFAULT 'GYD'::text,
  fijado_en       timestamptz NOT NULL DEFAULT now(),
  deal_id         uuid,
  cerrado_en      timestamptz,
  pedido          text,
  CONSTRAINT cerebro_objetivo_envio_pkey PRIMARY KEY (conversation_id),
  CONSTRAINT cerebro_objetivo_envio_monto_check CHECK (monto > 0::numeric),
  CONSTRAINT cerebro_objetivo_envio_conversation_id_fkey
    FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE
);

-- cerebro_revendedores — the reseller allow-list, keyed by phone. No repo
-- origin: never versioned before this migration.
CREATE TABLE IF NOT EXISTS public.cerebro_revendedores (
  phone  text NOT NULL,
  nombre text NOT NULL,
  activo boolean NOT NULL DEFAULT true,
  notas  text,
  creado timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cerebro_revendedores_pkey PRIMARY KEY (phone)
);

-- cerebro_servicios — the bot's per-service script data (the "hechos" the
-- agent recites for each service, keyed by clave). No repo origin: never
-- versioned before this migration — see THE LATENT BUG above.
CREATE TABLE IF NOT EXISTS public.cerebro_servicios (
  clave           text NOT NULL,
  nombre          text NOT NULL,
  activo          boolean NOT NULL DEFAULT true,
  hechos          text NOT NULL,
  enlace          text,
  requiere_humano boolean NOT NULL DEFAULT false,
  notas_internas  text,
  actualizado     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cerebro_servicios_pkey PRIMARY KEY (clave)
);

-- =====================================================================
-- ROW LEVEL SECURITY
--
-- All three carry `relrowsecurity = true` live, with ZERO policies
-- (`pg_policies` returns no rows for any of them — verified live, see this
-- task's report). RLS enabled with no policy at all is Postgres's
-- default-deny: `anon` and `authenticated` — neither of which has
-- BYPASSRLS (verified live: only `postgres` and `service_role` do) — can
-- see or touch zero rows through PostgREST, regardless of the GRANTs
-- below. `service_role` and the `postgres` owner bypass RLS entirely, so
-- n8n (which calls these tables only through the SECURITY DEFINER
-- cerebro_* functions, themselves owned by postgres) is unaffected. No
-- policy is created here because none exists live to capture.
ALTER TABLE public.cerebro_objetivo_envio ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cerebro_revendedores  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cerebro_servicios     ENABLE ROW LEVEL SECURITY;

-- =====================================================================
-- PRIVILEGES
--
-- `CREATE TABLE IF NOT EXISTS` does NOT preserve or reproduce privileges
-- on a database where the table does not exist yet — that only applies
-- when the statement is a no-op against an existing table. On a FRESH
-- database, a newly created table gets Postgres's plain default: no
-- explicit ACL, so only the owner has access and PUBLIC has nothing. That
-- is NOT what these three tables carry live.
--
-- The raw ACL observed live (`relacl`, identical across all three):
--   postgres=arwdDxtm/postgres
--   anon=arwdDxtm/postgres
--   authenticated=arwdDxtm/postgres
--   service_role=arwdDxtm/postgres
--
-- `arwdDxtm` is every table-level privilege (INSERT, SELECT, UPDATE,
-- DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN) — i.e. all four roles
-- hold the Supabase-platform default "ALL PRIVILEGES" grant that every
-- table in this schema carries, not something specific to these three.
-- This repo's migrations have never stated it explicitly for ANY table
-- (unlike 064's `ALTER DEFAULT PRIVILEGES ... ON FUNCTIONS`, there is no
-- `... ON TABLES` equivalent anywhere in this history), so nothing here
-- would reproduce it on a from-scratch build without saying so directly.
-- The wide GRANT looks alarming next to 109's function-level REVOKEs, but
-- it is safe: as the RLS section above shows, RLS with no policy is what
-- actually keeps `anon`/`authenticated` out, not the absence of a GRANT.
REVOKE ALL ON TABLE
  public.cerebro_objetivo_envio,
  public.cerebro_revendedores,
  public.cerebro_servicios
FROM PUBLIC;

GRANT ALL ON TABLE
  public.cerebro_objetivo_envio,
  public.cerebro_revendedores,
  public.cerebro_servicios
TO postgres, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
