-- =====================================================================
-- ROLLBACK-168 — undo "the client tag follows delivered operations"
--
-- Restores sync_tags_cliente to its pre-168 body, verbatim: the count goes
-- back to `deals` (pipeline Remesas + stage Entregada), and
-- md5(prosrc) returns to d0a05822c5116cd69e97c58721846724 with length
-- 1351. ACLs are untouched by CREATE OR REPLACE, so they survive
-- unchanged, and the owner stays postgres.
--
-- Staging/schema only. Never run against production.
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
  from deals d
  where d.contact_id = p_contact_id
    and d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
    and d.stage_id = '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';

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
