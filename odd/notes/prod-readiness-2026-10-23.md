# Production readiness for migrations 265-287 (read-only check, 2026-10-23)

Branch feat/port-chat-operations-calculator. Production hqztotshnlzaiziwjyzh read via catalog SELECTs only; staging
"before 265" state rebuilt by applying ROLLBACK-287..265 (270 excluded, already in production) in one rolled-back
transaction. No writes, no DDL, no n8n/panel contact.

## Verdict: CONDITIONAL GO (SQL side). NO-GO until the two ordering items in section 4 are agreed.

## 1. Migration history (supabase_migrations.schema_migrations)

| Item | Status |
|---|---|
| 004-264 repo files with a number >= 144 | all recorded, except 243 and 244 (below) |
| 242_recarga_tier_cost | RECORDED (20261021024952); objects identical to staging (see section 3) |
| 243_cerebro_cotizar | NOT recorded. `cerebro_cotizar` does not exist in production. Not required by any SQL in 265-287 (grep), but the staging n8n workflow consolidation calls it. Apply with the n8n window or before it (additive, one function) |
| 244_saldo_movil_catalog | NOT recorded, intentionally: superseded by 245_saldo_catalog_produccion (recorded). Not a blocker. 244 must NOT be applied (needs columns resumen/palabras_clave that production lacks) |
| 100-143 repo files | not recorded under these names. Production history uses a different legacy numbering for that era (e.g. 102_pausa_humana_caduca, 122_promo_dia_guyana). All objects referenced by 265-287 that I checked exist in production (47 of 47 names looked up; one false hit was a lock-key string). 138_service_catalog columns (resumen, palabras_clave) are absent in production and no file in 265-287 uses them. Not a blocker; do not apply 100-143 |
| 169_reparto_usd_card_rail | recorded as 167_reparto_usd_card_rail (renumbered). Not a blocker |
| 265, 266, 267, 268 | not recorded (pending) |
| 269 | no SQL file; it is the n8n-only change (cerebro-269-m5.md). Nothing to apply in the database |
| 270_cerebro_config_service_role_grant | RECORDED (20261022165736). service_role holds SELECT, INSERT, UPDATE on cerebro_config (also TRUNCATE, REFERENCES, TRIGGER, which are broader than 270 and were there before; informational) |
| 271-287 | not recorded (pending) |

Blockers in history below 265: none (243 is the only real gap and it is additive).

## 2. Base parity (production now vs staging before 265)

Compared md5 of pg_get_functiondef (exact and whitespace-normalized), function ACLs, and for the 5 touched tables
columns, constraints, triggers, indexes, policies, table ACLs.

| Object group | Result |
|---|---|
| 23 pre-existing functions redefined by 265-287 (calculator_resolve_operation_service, calculator_service_for_operation, _cambiar_servicio_core, _repartir_envio_core, _cerebro_partes_envio_parse, cerebro_dashboard_historial, cerebro_fijar_objetivo, cerebro_guardar_beneficiario, cerebro_guardar_beneficiario_auto, cerebro_guardar_zelle, cerebro_marcar_destino_usd, cerebro_minimo_gyd, cerebro_parsear_beneficiarios, cerebro_registrar_deposito, cerebro_repartir_envio, cerebro_resolver_para_guardar, cerebro_riel_op, crm_agregar_beneficiario, crm_beneficiarios_completos, crm_corregir_beneficiario, crm_operaciones_de_conversacion, crm_registrar_datos_entrega_efectivo, crm_registrar_numeros_recarga) | SAME body (23/23 identical md5) |
| 16 new functions (_cerebro_aplicar_plan_reparto, cerebro_aplicar_servicio, cerebro_declarar_servicio, cerebro_guardar_beneficiario_mexico, cerebro_limpiar_servicio_declarado, cerebro_modificar_operacion, _cerebro_nombre_servicio, _cerebro_operacion_declarada, _cerebro_op_parte, _cerebro_ops_para_datos, _cerebro_op_tiene_dinero, _cerebro_reparto_planear, cerebro_resolver_servicio, _cerebro_servicio_clave, _cerebro_texto_partes, _cerebro_usd_parte) | MISSING in production, as expected (created by the bundle) |
| remittance_operations: 31 columns, 8 constraints, 11 triggers, 10 indexes, 1 policy | SAME |
| remittance_beneficiaries: 22 columns, 5 constraints (incl. rb_type_chk), 3 triggers, 4 indexes, policy | SAME (policy text differs only in whitespace) |
| remittance_admin_audit: columns, remittance_admin_audit_action_chk (25 values), indexes, policy | SAME |
| cerebro_servicio_declarado, cerebro_reparto_planeado, remittance_beneficiaries.clabe / bank_name, rb_clabe_chk, rb_mexico_chk, trigger trg_remittance_operations_limpia_servicio_declarado | MISSING in production, as expected (created by 265/271/273/277) |
| Function ACLs on 11 functions | DIFFERENT only because staging has environment default grants (service_role EXECUTE; on 3 crm_* RPCs both have authenticated). Production keeps postgres-only (or postgres+authenticated). CREATE OR REPLACE keeps the production ACL. Same class of gap as 270 |
| Table ACLs (3 tables) | DIFFERENT: staging gives anon/authenticated full rights, production is stricter (anon/authenticated only Dxtm / rDxtm). Environment difference, production safer; the bundle does not alter these |

Conclusion: base is equivalent; the bundle applies on the same bodies staging started from.

Grant risk to note (not a blocker): new functions get production's default ACL (postgres only). Functions that other
roles must call carry explicit GRANTs in the files (cerebro_aplicar_servicio, cerebro_declarar_servicio,
cerebro_resolver_servicio to authenticated, service_role, cerebro_modificar_operacion, etc.). The bot connects as postgres
(existing production functions are postgres-only), so it is unaffected. Re-check after apply that the panel service-role
paths still work, since staging cannot show missing service_role grants (that is what hid 270).

## 3. Specific checks

| Check | Result |
|---|---|
| 242 in production | Present. Column calculator_rate_versions.recarga_costo_usdt_500 exists. md5 of calculator_feed_operation (8afa98fb), calculator_missing_rates (3157df72), crm_corregir_tasas_entrada_calculadora 4-arg (521b29f4), crm_resolve_pending_entry (874a3f1b), crm_set_calculator_rates (8d9f4d24) equal staging. The triage note (missing_inputs still asks recargaCostoUsdt while cost_gyd carries the tier cost) therefore applies identically in production: same inconsistency, no divergence |
| 270 grant | Present (see section 1) |
| remittance_admin_audit_action_chk widened in 271, 281, 282, 284, 287 | Widening only (25 -> 33 values, none removed). Rows with an action outside the final list: 0 of 538 |
| rb_type_chk (271) | Widening (adds mexico_cuenta, mexico_retiro). Violating rows: 0 of 225 (types in use: clasica, cuban_card, efectivo_usd, multiple_distribution, recarga, zelle) |
| rb_clabe_chk, rb_mexico_chk | New columns start NULL, so existing rows cannot violate: 0 |
| cerebro_servicio_declarado_servicio_check | New empty table: 0 |
| remittance_operations_service_chk | Not changed by the bundle (already allows mexico, saldo, traduccion) |

## 4. Ordering risks

1. 273 runs `UPDATE cerebro_servicios SET requiere_humano = false WHERE clave = 'mexico'`. In production it is
   currently true. Applying 273 makes the bot able to handle Mexico on its own: it must ship with the n8n change
   (declarar_servicio / agregar_servicio and the Mexico recipient step), or Mexico sales will go without the bot
   having the tools. Production already has 2 mexico operations (completed, ready_to_transfer) and the repo's
   Mexico recipient flow is staged but not live.
2. 265-268 replace the writers and the deposit with resolver-based versions. 267 needs the bot to declare the service
   (cerebro_declarar_servicio, a new tool, 269 on n8n). Until the n8n workflow declares services, deposits fall back
   to the resolver default (open operation, else Q1 promo/recarga, else remesa): behavior should stay safe but the
   declared-intent path is idle. Apply the DB first, n8n second (migrations before the app that needs them).
3. 283-287 change the semantics of modificar_operacion / correct recipient tools that exist only in the staging n8n
   workflow. The DB side is additive; the old production workflow does not call them.
4. 243 (cerebro_cotizar) must be in production before the n8n workflow that uses cerebro_cotizar is promoted.
5. Panel (Next.js) must not be published before 271 and 273 if it reads clabe / bank_name; publish after the DB.
6. Do not apply any ROLLBACK file. Do not apply 244 or 100-143.

## Recommended apply order

0. Owner go-ahead for each apply (skill rule). Run `previa` over all files in order; the expected verdict is SEGURO
   (this check found no DIFFERENT body).
1. 243_cerebro_cotizar (additive; only if the n8n consolidation ships in this window).
2. 265, 266, 267, 268 (resolver, apply service, deposit, writers).
3. 271, 272, 273 (Mexico). 273 flips requiere_humano for mexico: apply it in the n8n window.
4. 274-280 (Zelle recipients, declared operation, planned split, objective, message, partial split).
5. 281-287 (modificar_operacion, recarga quitar, rails, correct recipient, Zelle ambiguous, cash recipient, move deposit).
6. `verificar` over every file; then the n8n change; then the panel.
