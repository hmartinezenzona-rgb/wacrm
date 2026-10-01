-- =====================================================================
-- 168 — the client tag follows delivered OPERATIONS, not deals
--
-- PROBLEM
--   sync_tags_cliente(uuid) tags a contact Nuevo / Cliente / Recurrentes
--   from the number of DELIVERED DEALS: it counts rows in `deals` whose
--   pipeline is Remesas and whose stage is Entregada
--   (1b36b34c-1bf1-4095-9a86-5ec5ff945d2b). It is the last un-sliced
--   object of the deals removal: once the table is gone the function
--   stops counting.
--
--   It has NO defining migration. This is measured, not assumed: the only
--   place the repository names it is
--   065_revoke_rpc_wacrm_tanda_c.sql:17,47,61 — a REVOKE/GRANT pair that
--   assumes the function already exists. Its live body was captured from
--   pg_get_functiondef (md5(prosrc) = d0a05822c5116cd69e97c58721846724,
--   length 1351) and is what this migration ports into the repository.
--
-- FIX
--   Replace ONLY the count block. The old block counted
--     deals d WHERE d.pipeline_id = <Remesas> AND d.stage_id = <Entregada>
--   The new block counts
--     remittance_operations ro WHERE ro.status = 'completed'
--
--   Why 'completed' is the repository's own mapping, not an invention:
--   cerebro_estado_desde_etapa (041:38-45) maps the stage Entregada
--   (1b36b34c-...) to 'completed'. The pipeline filter is dropped because
--   it is vacuous (measured: `pipelines` holds exactly one row and all 35
--   deals live in it) and because a post-cutover operation has no pipeline
--   at all — dropping it is what lets deal-free operations count.
--
--   The deal -> operation mapping is injective, so the count cannot
--   inflate: remittance_operations_deal_uk is a UNIQUE index on (deal_id)
--   WHERE deal_id IS NOT NULL, and the live distribution is 34 deals with
--   exactly one operation each.
--
-- DELIBERATELY NOT DONE
--   * No service_type filter. A recarga that reached Entregada counts
--     today and keeps counting. Adding
--     coalesce(service_type,'remesa') <> 'recarga' would subtract the one
--     recarga operation that exists on staging — a behaviour change nobody
--     authorised. Recorded as an open product question, not decided here.
--   * No d.status filter on the old side either: the live predicate
--     ignores deal status entirely.
--   * Nothing else changes. The signature, the contract, the ACL, the
--     v_es_admin early return, the three lower(name) tag lookups, the
--     0 / <=2 / else ladder, the delete ... is distinct from v_objetivo,
--     the insert ... on conflict do nothing and gen_random_uuid() are all
--     byte-identical. (The tag_id IN (...) NULL-swallow when a tag row is
--     missing is PRE-EXISTING behaviour and is preserved, not fixed.)
--
--   ACL: 065 already revoked PUBLIC, anon and authenticated and granted
--   only service_role. CREATE OR REPLACE keeps the ACL; nothing is
--   re-granted here, and there is no REVOKE ... FROM authenticated to
--   template.
--
-- REPLAY NOTE
--   This is the first migration in the repository to define
--   sync_tags_cliente, and it lands at 168 — after 065. A from-zero replay
--   therefore still fails at 065. That hole predates this feature; it is
--   recorded here and intentionally NOT fixed by renumbering.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.sync_tags_cliente(p_contact_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_entregadas int;
  v_es_admin boolean;
  v_nuevo uuid;
  v_cliente uuid;
  v_rec uuid;
  v_objetivo uuid;
begin
  if p_contact_id is null then return; end if;

  select exists(
    select 1 from contact_tags ct join tags t on t.id = ct.tag_id
    where ct.contact_id = p_contact_id and lower(t.name) = 'admin'
  ) into v_es_admin;
  if v_es_admin then return; end if;

  select id into v_nuevo   from tags where lower(name) = 'nuevo'       limit 1;
  select id into v_cliente from tags where lower(name) = 'cliente'     limit 1;
  select id into v_rec     from tags where lower(name) = 'recurrentes' limit 1;

  select count(*) into v_entregadas
  from remittance_operations ro
  where ro.contact_id = p_contact_id
    and ro.status = 'completed';

  if v_entregadas = 0 then
    v_objetivo := v_nuevo;
  elsif v_entregadas <= 2 then
    v_objetivo := v_cliente;
  else
    v_objetivo := v_rec;
  end if;

  delete from contact_tags
  where contact_id = p_contact_id
    and tag_id in (v_nuevo, v_cliente, v_rec)
    and tag_id is distinct from v_objetivo;

  if v_objetivo is not null then
    insert into contact_tags (id, contact_id, tag_id)
    values (gen_random_uuid(), p_contact_id, v_objetivo)
    on conflict (contact_id, tag_id) do nothing;
  end if;
end;
$function$
