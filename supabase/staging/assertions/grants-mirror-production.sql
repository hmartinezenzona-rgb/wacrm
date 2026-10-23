\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 288 (explicit grants). Self-reverting: BEGIN ... ROLLBACK is in this file; the DO blocks end in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Production has narrow default privileges; staging has broad ones. Inside this transaction:
--   1  every public table / view is set to PRODUCTION's real ACL (read with catalog SELECTs on 2026-10-23) and the 33 functions of 243 + 265-287 to the production default
--      (postgres only); the two new tables to the production default for new tables (Dxtm only)
--   2  288's statements are applied again (the same text as the migration)
--   3  each agent-facing function runs AS service_role (SET LOCAL ROLE), each panel-facing function AS authenticated with a member's JWT claim, on fixtures built as
--      the owner; any permission denied (42501) fails; other errors (a business refusal) are fine, this proves privileges only
--   4  negative checks: the agent tools are not executable by anon / authenticated, the panel-only RPCs not by anon; no sequence is owned by the new tables
-- Objects that needed an explicit grant: see odd/notes/db-tools-progress.md (288).
-- =====================================================================
DO $m$
DECLARE r record; v_fn text; v_p text; v_roles text[] := ARRAY['anon','authenticated','service_role']; i int; v_letters text; v_privs text[];
BEGIN
  -- tables / views to production's ACL
  FOR r IN SELECT * FROM (VALUES
    ('account_invitations','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('accounts','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('ai_configs','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('ai_knowledge_chunks','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('ai_knowledge_documents','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('ai_usage_log','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('api_keys','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('automation_logs','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('automation_pending_executions','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('automation_steps','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('automations','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('broadcast_recipients','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('broadcasts','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('contact_custom_values','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('contact_notes','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('contact_tags','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('contacts','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('conversations','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('custom_fields','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('deals','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('flow_nodes','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('flow_run_events','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('flow_runs','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('flows','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('member_presence','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('message_reactions','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('message_templates','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('messages','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('notifications','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('pipeline_stages','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('pipelines','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('profiles','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('quick_replies','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('tags','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('webhook_endpoints','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('whatsapp_config','arwdDxtm','arwdDxtm','arwdDxtm'),
    ('calculator_feed_state','Dxtm','Dxtm','Dxtm'),
    ('calculator_rate_versions','','r','Dxtm'),
    ('cerebro_alertas','Dxtm','Dxtm','Dxtm'),
    ('cerebro_alertas_coherencia','','','Dxtm'),
    ('cerebro_alertas_enviadas','Dxtm','Dxtm','Dxtm'),
    ('cerebro_beneficiario_parcial','Dxtm','Dxtm','Dxtm'),
    ('cerebro_config','Dxtm','Dxtm','arwDxtm'),
    ('cerebro_cotizacion','','','Dxtm'),
    ('cerebro_destino_pendiente','','','Dxtm'),
    ('cerebro_ejecuciones','Dxtm','Dxtm','Dxtm'),
    ('cerebro_lecturas_vision','','','arDxtm'),
    ('cerebro_memoria','Dxtm','Dxtm','Dxtm'),
    ('cerebro_memoria_respaldo_dsml','Dxtm','Dxtm','Dxtm'),
    ('cerebro_objetivo_envio','','',''),
    ('cerebro_reintentos','Dxtm','Dxtm','Dxtm'),
    ('cerebro_revendedores','Dxtm','Dxtm','Dxtm'),
    ('cerebro_semantic_turn_audit','Dxtm','Dxtm','Dxtm'),
    ('cerebro_servicios','Dxtm','Dxtm','Dxtm'),
    ('cerebro_telemetria_turno','Dxtm','Dxtm','Dxtm'),
    ('cerebro_ultima_cotizacion','','','Dxtm'),
    ('cerebro_webhook_nonces','Dxtm','Dxtm','Dxtm'),
    ('comprobantes_hashes','Dxtm','Dxtm','Dxtm'),
    ('cup_cards','','r','Dxtm'),
    ('cup_lot_consumptions','','r','Dxtm'),
    ('cup_lots','','r','Dxtm'),
    ('depositos_mmg','Dxtm','rDxtm','Dxtm'),
    ('message_outbox','Dxtm','Dxtm','Dxtm'),
    ('precio_recarga','Dxtm','Dxtm','Dxtm'),
    ('promo_etecsa','Dxtm','Dxtm','Dxtm'),
    ('remittance_admin_audit','Dxtm','Dxtm','Dxtm'),
    ('remittance_beneficiaries','Dxtm','rDxtm','Dxtm'),
    ('remittance_beneficiary_proofs','','rxtm','Dxtm'),
    ('remittance_calculator_documents','','r','arwDxtm'),
    ('remittance_calculator_entries','','r','arwdDxtm'),
    ('remittance_calculator_week_entries','','r','arwdDxtm'),
    ('remittance_calculator_weeks','','r','arwdDxtm'),
    ('remittance_operation_receipts','Dxtm','Dxtm','Dxtm'),
    ('remittance_operations','Dxtm','rDxtm','Dxtm'),
    ('session_events','Dxtm','Dxtm','Dxtm'),
    ('tasas_historico','','','rDxtm'),
    ('tool_execution_log','Dxtm','Dxtm','Dxtm'),
    ('whatsapp_webhook_log','Dxtm','Dxtm','arwdDxtm'),
    ('calculator_current_entries','','rDxtm','rDxtm'),
    ('calculator_unfed_operations','Dxtm','Dxtm','Dxtm'),
    ('cerebro_historial_operaciones','','Dxtm','Dxtm'),
    ('cerebro_outbox_salud','Dxtm','Dxtm','Dxtm'),
    ('cerebro_resumen_volumen','','Dxtm','Dxtm'),
    ('cerebro_volumen_diario','','Dxtm','Dxtm'),
    ('tasas','','','rDxtm')
  ) AS t(rel, anon_l, auth_l, svc_l) LOOP
    CONTINUE WHEN to_regclass('public.' || r.rel) IS NULL;
    FOR i IN 1 .. 3 LOOP
      v_letters := CASE i WHEN 1 THEN r.anon_l WHEN 2 THEN r.auth_l ELSE r.svc_l END;
      EXECUTE format('REVOKE ALL ON public.%I FROM %I', r.rel, v_roles[i]);
      v_privs := ARRAY[]::text[];
      IF position('a' in v_letters) > 0 THEN v_privs := v_privs || 'INSERT'::text; END IF;
      IF position('r' in v_letters) > 0 THEN v_privs := v_privs || 'SELECT'::text; END IF;
      IF position('w' in v_letters) > 0 THEN v_privs := v_privs || 'UPDATE'::text; END IF;
      IF position('d' in v_letters) > 0 THEN v_privs := v_privs || 'DELETE'::text; END IF;
      IF position('D' in v_letters) > 0 THEN v_privs := v_privs || 'TRUNCATE'::text; END IF;
      IF position('x' in v_letters) > 0 THEN v_privs := v_privs || 'REFERENCES'::text; END IF;
      IF position('t' in v_letters) > 0 THEN v_privs := v_privs || 'TRIGGER'::text; END IF;
      IF cardinality(v_privs) > 0 THEN EXECUTE format('GRANT %s ON public.%I TO %I', array_to_string(v_privs, ', '), r.rel, v_roles[i]); END IF;
    END LOOP;
  END LOOP;
  -- the two new tables: production's default for a new table
  FOREACH v_p IN ARRAY ARRAY['cerebro_servicio_declarado', 'cerebro_reparto_planeado'] LOOP
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', v_p);
    EXECUTE format('GRANT TRUNCATE, REFERENCES, TRIGGER ON public.%I TO anon, authenticated, service_role', v_p);
  END LOOP;
  -- the functions: production default (postgres only)
  FOREACH v_fn IN ARRAY ARRAY[
    'public.cerebro_aplicar_servicio(uuid,text,text,text,text)',
    'public.cerebro_declarar_servicio(uuid,text,text)',
    'public.cerebro_cotizar(uuid,numeric,text,text,text,text)',
    'public.cerebro_fijar_objetivo(uuid,numeric,text)',
    'public.cerebro_guardar_beneficiario(uuid,text,text,text,text,uuid,text,integer,text)',
    'public.cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text)',
    'public.cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)',
    'public.cerebro_marcar_destino_usd(uuid,text,text)',
    'public.cerebro_modificar_operacion(uuid,uuid,text,jsonb,text)',
    'public.cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)',
    'public.cerebro_repartir_envio(uuid,text,text)',
    'public.crm_registrar_datos_entrega_efectivo(uuid,text,text,text,text)',
    'public.crm_registrar_numeros_recarga(uuid,text,boolean,text,text)',
    'public.cerebro_parsear_beneficiarios(text)',
    'public.crm_operaciones_de_conversacion(uuid)',
    'public.cerebro_dashboard_historial(date,date,text,integer,integer)',
    'public.cerebro_resolver_servicio(uuid,text,text,numeric,timestamp with time zone)',
    'public.crm_agregar_beneficiario(uuid,jsonb)',
    'public.crm_beneficiarios_completos(uuid)',
    'public.crm_corregir_beneficiario(uuid,jsonb)',
    'public._cambiar_servicio_core(uuid,text,text,text,text)',
    'public._cerebro_aplicar_plan_reparto(uuid,uuid)',
    'public._cerebro_nombre_servicio(text)',
    'public._cerebro_op_parte(uuid,text,text,text)',
    'public._cerebro_op_tiene_dinero(uuid)',
    'public._cerebro_operacion_declarada(uuid,text,text)',
    'public._cerebro_ops_para_datos(uuid,text)',
    'public._cerebro_partes_envio_parse(text)',
    'public._cerebro_reparto_planear(uuid,jsonb,boolean,text)',
    'public._cerebro_servicio_clave(text)',
    'public._cerebro_texto_partes(jsonb)',
    'public._cerebro_usd_parte(text,numeric)',
    'public._repartir_envio_core(uuid,jsonb,text,text,text,boolean)',
    'public.calculator_resolve_operation_service(uuid,text)',
    'public.cerebro_guardar_beneficiario_auto(uuid,text,text,text,text,text)',
    'public.cerebro_limpiar_servicio_declarado()',
    'public.cerebro_minimo_gyd(uuid)',
    'public.cerebro_resolver_para_guardar(uuid,text,text,jsonb,uuid)',
    'public.cerebro_riel_op(uuid)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', v_fn);
  END LOOP;
END $m$;

-- 288 re-applied (same text as the migration)
-- Functions: explicit state for every function created or replaced by 243 and 265-287 (production default is postgres only).
-- agent-facing: service_role
REVOKE ALL ON FUNCTION public.cerebro_aplicar_servicio(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_aplicar_servicio(uuid, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_fijar_objetivo(uuid, numeric, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_fijar_objetivo(uuid, numeric, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_modificar_operacion(uuid, uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_modificar_operacion(uuid, uuid, text, jsonb, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_parsear_beneficiarios(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_parsear_beneficiarios(text) TO service_role;
-- panel + agent: authenticated, service_role
REVOKE ALL ON FUNCTION public.crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_operaciones_de_conversacion(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamp with time zone) TO authenticated, service_role;
-- panel-facing: authenticated
REVOKE ALL ON FUNCTION public.crm_agregar_beneficiario(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_agregar_beneficiario(uuid, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.crm_beneficiarios_completos(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_beneficiarios_completos(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.crm_corregir_beneficiario(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_corregir_beneficiario(uuid, jsonb) TO authenticated;
-- internal helpers: postgres only (SECURITY DEFINER callers run as the owner)
REVOKE ALL ON FUNCTION public._cambiar_servicio_core(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_aplicar_plan_reparto(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_nombre_servicio(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_op_parte(uuid, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_op_tiene_dinero(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_operacion_declarada(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_ops_para_datos(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_partes_envio_parse(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_reparto_planear(uuid, jsonb, boolean, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_servicio_clave(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_texto_partes(jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_usd_parte(text, numeric) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._repartir_envio_core(uuid, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.calculator_resolve_operation_service(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_limpiar_servicio_declarado() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_minimo_gyd(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_resolver_para_guardar(uuid, text, text, jsonb, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_riel_op(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- New tables (production default would give anon / authenticated / service_role only Dxtm): RLS stays on, the bot's service role gets row access.
REVOKE ALL ON TABLE public.cerebro_servicio_declarado FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cerebro_servicio_declarado TO service_role;
REVOKE ALL ON TABLE public.cerebro_reparto_planeado FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cerebro_reparto_planeado TO service_role;


DO $a$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_ben uuid;
  v_convs uuid[] := ARRAY[]::uuid[]; v_fail text[] := ARRAY[]::text[]; v_ok int := 0; r record; v_sql text; v_c uuid; v_n int := 0;
  v_calls_svc text[][] := ARRAY[
    ARRAY['declarar', $q$SELECT cerebro_declarar_servicio('%C%'::uuid,'zelle','agent:t')$q$],
    ARRAY['aplicar', $q$SELECT cerebro_aplicar_servicio('%C%'::uuid,'zelle','cambiar','agent:cambiar_servicio','g')$q$],
    ARRAY['resolver', $q$SELECT cerebro_resolver_servicio('%C%'::uuid)$q$],
    ARRAY['cotizar', $q$SELECT cerebro_cotizar('%C%'::uuid,100,'hacia_destino','usd','zelle','g')$q$],
    ARRAY['fijar', $q$SELECT cerebro_fijar_objetivo('%C%'::uuid,26000,'GYD')$q$],
    ARRAY['guardar_benef', $q$SELECT cerebro_guardar_beneficiario('%C%'::uuid,'Ana Gil','9999000000000008','53821203','g')$q$],
    ARRAY['benef_mexico', $q$SELECT cerebro_guardar_beneficiario_mexico('%C%'::uuid,'mexico_cuenta','012345678901234567','Banco','Ana Perez',NULL,'g')$q$],
    ARRAY['zelle', $q$SELECT cerebro_guardar_zelle('%C%'::uuid,'Marta Gil','mg@example.com','g')$q$],
    ARRAY['marcar', $q$SELECT cerebro_marcar_destino_usd('%C%'::uuid,'clasica','g')$q$],
    ARRAY['modificar', $q$SELECT cerebro_modificar_operacion('%C%'::uuid,NULL,'monto','26000'::jsonb,'agent:modificar_operacion n8n:g')$q$],
    ARRAY['deposito', $q$SELECT cerebro_registrar_deposito('%C%'::uuid,26000,'GYD','3cf01654-cd27-47c1-ac92-62abf5435751'::uuid,'DEPOSITO: 26,000 GYD - EXITOSA'||chr(10)||'Ref: 90409990040001','COMP-'||substr(md5('g'),1,20))$q$],
    ARRAY['repartir', $q$SELECT cerebro_repartir_envio('%C%'::uuid,'zelle 20000, clasica 6000','g')$q$],
    ARRAY['efectivo', $q$SELECT crm_registrar_datos_entrega_efectivo('%C%'::uuid,'53821204','Calle 1 Bayamo',NULL,'Rosa Gomez')$q$],
    ARRAY['recarga', $q$SELECT crm_registrar_numeros_recarga('%C%'::uuid,'55501111',true,'agent:registrar_numeros_recarga','agregar')$q$],
    ARRAY['parsear', $q$SELECT cerebro_parsear_beneficiarios('BENEFICIARIO'||chr(10)||'Tarjeta: 9999000000000008')$q$],
    ARRAY['tabla_declarado', $q$SELECT (SELECT count(*) FROM cerebro_servicio_declarado)$q$],
    ARRAY['tabla_reparto', $q$SELECT (SELECT count(*) FROM cerebro_reparto_planeado)$q$]
  ];
  v_calls_auth text[][] := ARRAY[
    ARRAY['operaciones', $q$SELECT crm_operaciones_de_conversacion('%C%'::uuid)$q$],
    ARRAY['dashboard', $q$SELECT cerebro_dashboard_historial(current_date - 30, current_date, NULL, 10, 0)$q$],
    ARRAY['resolver', $q$SELECT cerebro_resolver_servicio('%C%'::uuid)$q$],
    ARRAY['agregar_benef', $q$SELECT crm_agregar_beneficiario('%O%'::uuid,jsonb_build_object('beneficiary_type','efectivo_usd','name','Rosa','phone','53821204','address','Calle 1'))$q$],
    ARRAY['completos', $q$SELECT crm_beneficiarios_completos('%O%'::uuid)$q$],
    ARRAY['corregir', $q$SELECT crm_corregir_beneficiario('%B%'::uuid,jsonb_build_object('name','Otra'))$q$],
    ARRAY['repartir_panel', $q$SELECT crm_repartir_envio('%O%'::uuid,jsonb_build_array(jsonb_build_object('servicio','zelle','monto_gyd',20000),jsonb_build_object('servicio','clasica','monto_gyd',6000)))$q$],
    ARRAY['tabla_ops', $q$SELECT (SELECT count(*) FROM remittance_operations)$q$],
    ARRAY['tabla_benef', $q$SELECT (SELECT count(*) FROM remittance_beneficiaries)$q$]
  ];
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  -- fixtures as the owner: one conversation per call (a Zelle operation with a recipient on each)
  FOR i IN 1 .. 40 LOOP
    INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_user, '5990288' || lpad(i::text, 4, '0'), 'PRUEBA grants ' || i, v_acc) RETURNING id INTO v_ct;
    INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_conv;
    v_convs := v_convs || v_conv;
  END LOOP;
  FOREACH v_c IN ARRAY v_convs LOOP
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
    SELECT v_acc, v_c, contact_id, 'collecting_information', 'remesa', 'zelle', 'GYD', 26000 FROM conversations WHERE id = v_c;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
    SELECT o.id, 'zelle', 'Titular', 'titular' || substr(v_c::text, 1, 8) || '@example.com', 1, 1, 'notes_parse', 'vigente' FROM remittance_operations o WHERE o.conversation_id = v_c;
  END LOOP;

  -- agent-facing, AS service_role
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  SET LOCAL ROLE service_role;
  FOR i IN 1 .. array_length(v_calls_svc, 1) LOOP
    v_n := v_n + 1; v_conv := v_convs[v_n];
    v_sql := replace(v_calls_svc[i][2], '%C%', v_conv::text);
    BEGIN
      EXECUTE v_sql; v_ok := v_ok + 1;
    EXCEPTION WHEN insufficient_privilege THEN v_fail := v_fail || ('service_role ' || v_calls_svc[i][1] || ': ' || SQLERRM);
              WHEN OTHERS THEN v_ok := v_ok + 1; RAISE NOTICE '% not a privilege error: % %', v_sql, SQLSTATE, left(SQLERRM, 80);
    END;
  END LOOP;
  RESET ROLE;

  -- panel-facing, AS authenticated with a member's JWT claim
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  FOR i IN 1 .. array_length(v_calls_auth, 1) LOOP
    v_n := v_n + 1; v_conv := v_convs[v_n];
    -- ids are read as the owner would see them; the operation / recipient of this conversation
    RESET ROLE;
    SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv LIMIT 1;
    SELECT b.id INTO v_ben FROM remittance_beneficiaries b WHERE b.operation_id = v_op LIMIT 1;
    SET LOCAL ROLE authenticated;
    v_sql := replace(replace(replace(v_calls_auth[i][2], '%C%', v_conv::text), '%O%', v_op::text), '%B%', v_ben::text);
    BEGIN
      EXECUTE v_sql; v_ok := v_ok + 1;
    EXCEPTION WHEN insufficient_privilege THEN v_fail := v_fail || ('authenticated ' || v_calls_auth[i][1] || ': ' || SQLERRM);
              WHEN OTHERS THEN v_ok := v_ok + 1; RAISE NOTICE '% not a privilege error: % %', v_sql, SQLSTATE, left(SQLERRM, 80);
    END;
  END LOOP;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  IF cardinality(v_fail) > 0 THEN RAISE EXCEPTION 'permission denied in % call(s): %', cardinality(v_fail), array_to_string(v_fail, ' | '); END IF;

  -- negative checks
  IF has_function_privilege('authenticated', 'public.cerebro_modificar_operacion(uuid,uuid,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_aplicar_servicio(uuid,text,text,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crm_corregir_beneficiario(uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.crm_agregar_beneficiario(uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._repartir_envio_core(uuid,jsonb,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a function is executable by a role production does not give it';
  END IF;
  IF NOT (has_function_privilege('service_role', 'public.cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)', 'EXECUTE')
          AND has_function_privilege('authenticated', 'public.crm_corregir_beneficiario(uuid,jsonb)', 'EXECUTE')
          AND has_table_privilege('service_role', 'public.cerebro_servicio_declarado', 'SELECT,INSERT,UPDATE,DELETE')
          AND has_table_privilege('service_role', 'public.cerebro_reparto_planeado', 'SELECT,INSERT,UPDATE,DELETE')
          AND NOT has_table_privilege('authenticated', 'public.cerebro_reparto_planeado', 'SELECT')
          AND NOT has_table_privilege('anon', 'public.cerebro_servicio_declarado', 'SELECT')) THEN
    RAISE EXCEPTION 'expected grants missing';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_depend d ON d.objid = c.oid JOIN pg_class t ON t.oid = d.refobjid
              WHERE c.relkind = 'S' AND t.relname IN ('cerebro_servicio_declarado', 'cerebro_reparto_planeado')) THEN
    RAISE EXCEPTION 'a sequence is owned by the new tables: it needs an explicit grant';
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $a$;
ROLLBACK;
