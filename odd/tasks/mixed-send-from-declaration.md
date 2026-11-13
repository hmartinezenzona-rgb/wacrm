# Feature: a mixed send is registered when the customer declares two services, even with data missing

## Objective
When the customer asks for two services in one request (e.g. 2 recargas + 50 USD Zelle) and the bot registers one and quotes
the other, the planned split (cerebro_reparto_planeado + one operation per part with its agreed amount) exists from that
turn, so the panel shows the mixed send waiting for the deposit. It must not depend on the model remembering to call
repartir_envio.

## Problem / why (2026-11-13, owner test conv 2ca2cf79, exec 727547, no-Decisor test mode)
- One message: "2 recargas a <2 numbers> y también un zelle de 50 USD" (no Zelle account yet). Tools in that execution:
  registrar_numeros_recarga (op recarga, agreed 12,400, 2 numbers), consultar_servicio, calcular_usd (13,000 GYD, zelle).
  repartir_envio was NOT called: no plan, no Zelle operation. The panel showed one loose recarga operation; the Zelle the
  customer asked for was recorded nowhere. Reply text was right (total 25,400, asks the Zelle name and account).
- 369/370 (production 2026-11-13) show a plan as one mixed send, but only when a plan exists.
- Unknown: whether the production Decisor notes make the model call repartir_envio in this shape (test ran without them).

## Owner decisions
- 2026-11-13: "si, arréglalo así": the plan is created as soon as the customer declares two services with their amounts, in
  the database, not depending on the bot using the tool.

## Scope
In: SQL (migration 371+, ROLLBACK, staging assertions). Staging; production with go-ahead.
Out: Decisor, prompt, panel (369/370 already render a plan), n8n nodes unless a tool node must pass an extra argument
(then report, do not edit n8n).

## Constraints
- A price question is not a declaration: never plan from a quote alone when the customer did not ask for both (see T1).
- No mixed_group_id before the deposit (369 decision); parts get agreed amounts (not money); deposit behaviour unchanged.
- Read LIVE production bodies first and confirm they match the repo before redefining. Strict TDD: SQL assertions in rolled-back
  transactions, RED then GREEN. Related assertions stay green.
- Never touch the other session's files (pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts,
  pruebas/decisor/decisor-notas.test.ts, odd/tasks/bot-brevedad.md). No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Map and design (STOP and report before writing SQL): what each tool call leaves in the database in that turn
      (registrar_numeros_recarga, calcular_usd / calcular_envio -> cerebro_registrar_cotizacion / cerebro_ultima_cotizacion,
      consultar_servicio, "servicio declarado" state and its trigger, execution id available to each function), which
      deterministic signal means "two services declared" vs "price question", how a wrong plan is undone (customer drops a
      part, deposits only one part), and the proposed trigger point with its false-positive cases
- [x] T2 Implementation + assertions (exec 727547 shape; price-question negative; second service data arriving later; drop a part)
- [x] T3 Staging: apply, related assertions
- [x] T4 Production (needs go-ahead)
- [ ] T5 Surface the doubt so the bot asks: n8n "Contexto conversacion" adds `cerebro_declaracion_pendiente(v.id) AS declaracion_pendiente`
      (staging, then production with go-ahead); production Decisor note from ctx.declaracion_pendiente (vitest RED/GREEN, md5 pin);
      publish with go-ahead

## Acceptance criteria
- "2 recargas + Zelle 50 USD" in one request, Zelle account missing -> plan recarga 12,400 + zelle 13,000 (total 25,400) and the
  two part operations exist after that turn.
- "recarga a X; ¿cuánto sale un zelle de 50?" (question only) -> no plan.
- Existing split/plan/deposit assertions green.

## Progress / evidence

### T1 findings (2026-11-13, read-only; production bodies read live, n8n workflow jEzlVLCLUaJhVwzs GET only)

**1. What each tool leaves in the DB in one turn**
- Execution id: `calcular_usd`, `calcular_usd_desde_gyd`, `calcular_envio`, `registrar_beneficiario_zelle`, `registrar_reparto_multiple`,
  `cambiar_servicio`, `repartir_envio` receive `$execution.id`. NOT passed: `registrar_numeros_recarga` (conv + text only), `consultar_servicio`
  (service name only, writes nothing), `registrar_destinatario_combo`. So "same execution" cannot be read off the recarga write; it can only be
  joined by conversation + time (`cerebro_ejecuciones.created_at` of the execution is the turn start).
- `registrar_numeros_recarga` -> `crm_registrar_numeros_recarga(conv, text, p_abrir=>true)`: opens/reuses the recarga op, inserts one beneficiary row per
  number, `cerebro_declarar_servicio(conv,'recarga','automation:registrar_numeros_recarga')` (row in `cerebro_servicio_declarado`, one per conversation, latest
  wins), and writes the AGREED amount (promo price x numbers) with an `agent_amount_change` audit (`after.agreed=true`). Not logged in `tool_execution_log`.
- `calcular_usd` / `calcular_usd_desde_gyd` / `calcular_envio`: upsert `cerebro_ultima_cotizacion` (one row per destination currency: CUP / USD, so the USD quote
  is overwritten each time; no execution id), call `cerebro_fijar_objetivo` (calcular_usd only; sets `cerebro_objetivo_envio` only when a commitment exists,
  and an open recarga op counts as one), and `cerebro_registrar_via_cotizada` -> one `tool_execution_log` row (tool_name = the calc tool, outcome = via, arguments
  = [gyd, via]) ONLY when `via` is non-empty (a via-less calcular_usd leaves no log row; it is priced as Zelle). None of them opens an operation or a declaration.
- `cambiar_servicio`: converts the single open op to the new rail (or stores `cerebro_destino_pendiente` when no op exists); logs outcome. It is a change, not an add.
- `registrar_beneficiario_zelle` (`cerebro_guardar_zelle`): recipient writer; opens a send when none open ("recipient write opened a new send", actor
  `automation:recipient_writer`). `repartir_envio` (`cerebro_repartir_envio`): no op holding money -> `_cerebro_reparto_planear(conv, parts, true, 'agent:repartir_envio')`
  = row in `cerebro_reparto_planeado` + one empty op per part with its agreed amount (369); logs outcome `planeado`.
- "Declared service" = `cerebro_servicio_declarado(conversation_id PK, servicio, declarado_at, actor)`. Cleared (with the plan) by
  `trg_remittance_operations_limpia_servicio_declarado` only when an op reaches completed/cancelled AND no other op of the conversation is still open.
  `cerebro_guardia_envio_nuevo` uses `_cerebro_senal_envio_nuevo` ("declared service, pending rail, or deposit newer than the last completed send") to decide
  whether data opens a new send after a completed one; a quote or agreed amount alone does not count (owner 2026-11-08).
- Exec 727547 footprint (production, owner test conv 2ca2cf79, before the resets): recarga op 12,400 (agreed audit), `cerebro_ultima_cotizacion` USD 13,000/50 by
  calcular_usd, log row calcular_usd outcome zelle args [13000,"zelle"], objective 13,000 GYD "50 USD" (set by calcular_usd, closed at the reset), no plan, no Zelle
  op. The recarga audit and the quote landed in the same second. Prior test exec 725623 (account given) DID call repartir_envio -> plan recarga 12,400 + zelle 13,000.
- `_cerebro_declarar_implicito` / `cerebro_cotizar` (implicit declaration from a quote) exist but no node in the production workflow calls them any more.

**2. Real data (last 30 days, production)**
- 116 quote log rows in 113 executions; only 13 agreed-amount audits (10 conversations). Quote for service Y within 180 s of an agreed-amount write for X != Y:
  4 pairs, 3 executions: 545752 (conv a6d28009, 2026-10-26: Zelle and Clasica quoted in one turn, two implicit ops with agreed amounts; the Clasica one was a
  comparison and staff deleted it, Zelle completed; a real Zelle+CUP mixed send was formed 20 min later by repartir_envio exec 545969), and the two owner tests
  725623 (model called repartir_envio, planned) and 727547 (it did not). No customer-driven case matches the 727547 shape in 30 days.
- Mixed sends in 30 days: 6 conversations with a group (f8b7779c, 4afda26a, 68a00ea7, a6d28009, fe5cf541, f501d3bf); repartir_envio 8 calls: 4 repartido, 3 planeado
  (d9e9f333 x2 and the test 2ca2cf79), 1 rechazado (1727ef31). The bot reaches repartir_envio only after data of the second service exists (Zelle account or card).
- Counter-example (587286, conv 4b3c89d1, 2026-10-30): after a recarga op, a CUP price quote in a later execution, then a separate CUP send paid on its own; no group,
  no plan. A quote for another service shortly after a recarga is NOT a mixed send; only the same turn is evidence.
- Customer text containing both "recarga" and "zelle": 1 message in 30 days (conv 1727ef31, 2026-10-25, ended in a rejected repartir 2026-11-07).
- Nothing stale today: 0 plans and 0 old empty ops in production.

**3. Candidate signals**
- (a) same turn: recarga/X agreed op written this turn AND a quote tool for Y != X with an amount, no money, no plan. Ambiguous alone: "recarga a X; cuanto sale un zelle
  de 50?" produces identical tool calls (the bot-change-service doc already concluded quote-to-compare and quote-to-switch cannot be told apart from bot-side
  evidence). Needs the customer's text as a VETO only (words never open services, 268; they may only prevent).
- (b) recipient writer for Y (account/card) while an unfunded agreed op of X is open and no plan: strong (nobody sends an account to ask a price) but late and
  silent in the 727547 shape (no account). Needs a Y amount from a recent quote, so it still depends on a quote row. Complementary, not sufficient. False positive:
  customer switches X -> Y ("mejor zelle"): the resolver converts, the hook must not add a second part (guard: X op already converted / no open X op).
- (c) explicit declaration tool (cambiar_servicio / repartir_envio): model-dependent (the very failure), and cambiar_servicio means replace.
- Where to hook: n8n node `Verificar coherencia servicio` runs after Agente Remesas on every agent turn with ($('Decisor').conversation_id, $execution.id),
  alwaysOutputData + onError continueRegularOutput. Putting the logic inside `cerebro_verificar_coherencia_servicio` (or a helper it calls first, in a
  BEGIN..EXCEPTION block) needs NO n8n change and sees the final state of the turn whatever the tool order was. That function already has the precedent
  "quoted one service, operation is on another" but only alerts staff, and returns early for non-remesa ops (recarga) and for >1 open op.
- Undo today: customer drops a part -> `cerebro_modificar_operacion('cancelar')` (empty op only; part leaves the plan; a plan left with 1 part lingers); deposit of one
  part only -> deposit lands on the plan's first listed part, no auto-split (needs deposit == plan total), Decisor `reparto_pendiente` note, then repartir_envio with the
  covered parts takes the partial path (280) and the other part stays pending; a new repartir_envio replaces a plan only via the ok path (a refused attempt never
  overwrites it); amount change of a part rewrites the plan. Stale lifetime: no cron expires plans or empty ops; the plan dies only when the last open op closes, the
  last part is cancelled, or a full repartir applies it. A wrong hook plan therefore leaves an empty Zelle op open until the customer/staff cancels it.

**4. Production Decisor / prompt on repartir_envio**
- Decisor (pruebas/decisor/produccion/decisor.jscode) mentions repartir_envio in two notes only: (i) multi-card reparto + Zelle data present ("if the deposit is
  already registered, call repartir_envio too"), (ii) a verified deposit exactly equal to a plan already stored. Nothing tells the model to plan before the deposit,
  and with a recarga open and no Zelle data (`s.datos_zelle` false) `recargaEnCurso` fires "RECARGA: only the phone number is needed", pushing single-service handling.
- The Agente Remesas system prompt (not the Decisor) is contradictory: repartir_envio "only when the customer confirms the parts" vs "if the send carries several
  services call repartir_envio FIRST in this same turn". That prompt was active in the failed test. Judgement: with the Decisor the model would probably still NOT
  call it in the 727547 shape (no account, no deposit); 725623 shows it calls it when Zelle data is present. Not measured (would need wacrm-medir-bot).

**Recommended design (for owner decision)**: see "Design proposal" below.

### Design proposal (T1 output)
- Trigger: new internal `_cerebro_declaracion_doble(p_conv, p_exec)` called as the FIRST statement of `cerebro_verificar_coherencia_servicio` inside
  BEGIN .. EXCEPTION WHEN OTHERS THEN RAISE WARNING (never breaks the coherence check or the turn). End-of-turn, so tool order does not matter. SQL only, n8n untouched.
- Guards, all required: (1) exec id present and `cerebro_ejecuciones` gives the turn start T0; (2) no plan row, no op in a mixed group; (3) in this exec exactly one
  distinct quoted service Y (log rows of calcular_usd / calcular_usd_desde_gyd with via; fallback: `cerebro_ultima_cotizacion` USD row with cotizado_en >= T0 = Zelle),
  GYD amount from the quote, >= the minimum of Y; two different Y in the turn = comparison, skip; (4) exactly one open op of service X != Y, unfunded, ungrouped,
  agreed amount (`_cerebro_op_monto_acordado`) whose agent_amount_change audit is >= T0; at most one other open op and only an empty one of Y or X; (5) customer
  text of the turn (messages.sender_type='customer', from T0 minus the debounce window) names Y's service word AND has no price-question marker ('?', cuanto,
  precio, sale, cuesta, tasa, cotiz); no customer text found = skip (when in doubt, do nothing).
- Action: `_cerebro_reparto_planear(conv, [{servicio X, monto_gyd = X agreed}, {servicio Y, monto_gyd = quote GYD}], true, 'automation:declaracion_doble')` (X first: the
  part listed first takes the deposit, 280); one `tool_execution_log` row (tool_name `declaracion_doble`, key exec||':declaracion_doble', outcome planeado / omitido:<motivo>) for
  audit and idempotence. No mixed_group_id, no money, deposit path unchanged.
- Accepted false positives: customer declarative-sounding sentence that was only a "maybe" ("y un zelle de 50 a lo mejor") -> empty Zelle op + plan in the panel;
  undone by cancelar of that part or panel delete, never touches money. The cost is the stale empty op (no expiry exists today); same class already accepted by the
  280 pending part.
- Misses accepted (status quo, no regression): audio-only requests (no text), a Y quote without explicit amount, three services, X as a remesa rail, Zelle data first.
- Assertions for T2 (rolled-back transactions, RED first): 727547 shape -> plan recarga 12400 + zelle 13000 (total 25400) and 2 ops with agreed amounts, no group, no money;
  question-only text -> no plan; two different Y quoted -> no plan; Y quote from an earlier execution (587286 shape) -> no plan; plan already present -> unchanged;
  no text -> no plan; replay of the same exec -> one plan; X op funded -> no plan; after the plan: data of Y arriving later fills the Y op (reused by _cerebro_op_parte);
  cancelar of one part -> the other op and plan consistent (1-part plan does not break a normal deposit); deposit of 25,400 applies the plan and raises no incident with
  objective 13,000 left by calcular_usd; deposit of only 12,400 -> lands on recarga, Zelle part stays pending; function raising inside the hook leaves the coherence result intact.
- Alternatives rejected: (R1) hook inside the quote tools / `cerebro_registrar_via_cotizada`: runs at price time, order dependent (recarga may not exist yet), the
  10-26 implicit:cotizar comparison op is exactly this failure class; (R2) hook inside `registrar_numeros_recarga` reading `cerebro_ultima_cotizacion`: no execution id, a
  quote up to 6 h old would qualify (587286 shape), order dependent; (R3) re-wire `_cerebro_declarar_implicito`/cerebro_cotizar: same comparison-op problem, would need n8n edit;
  (R4) alert only (extend the coherence alert): staff gets a notification but no plan, owner chose the plan; (R5) text-only trigger: words open services, forbidden by 268,
  fragile on audio; text is kept as veto only; (R6) Decisor/prompt change: out of scope and model-dependent (the failure); (R7) trigger on recipient writer only (signal b):
  silent in the 727547 shape; keep as a possible second phase (T2 "second service data arriving later" is covered because the Y op is reused).
- Open owner questions: (1) accept the text veto/requirement (G5) or prefer tool-only evidence with the price-question false positive? (2) add an expiry for
  empty hook-made ops/plans (none exists, out of scope here)? (3) should the hook also set the objective to the plan total? (277 does not; assert it is harmless).

- 2026-11-13 owner direction after T1: implement it; principle "the tools must be able to do what the bot confirms in the chat;
  when in doubt, ask; the bot must adapt to how customers ask, including shapes not seen yet". Design decisions (parent):
  the recommended design (_cerebro_declaracion_doble at end of turn inside cerebro_verificar_coherencia_servicio, all guards,
  customer text only as requirement + veto); objective = plan total after the hook plans; no expiry for plans (unchanged);
  "when in doubt, ask": when the tool evidence matches (X written this turn + exactly one Y quoted) but the text guard fails or is
  ambiguous, create nothing and leave a pending fact (row/flag readable by the context) so the next turn can ask the customer
  whether he also wants Y; report where that fact should surface (Contexto conversacion field) without editing n8n or the Decisor.


### T2 evidence (2026-11-13)
- Live production bodies read read-only before redefining: `cerebro_verificar_coherencia_servicio` md5 5b849da27e0478a0626e0df56331c397 (= staging, = the
  fingerprint recorded in odd/tasks/bot-change-service.md), `_cerebro_reparto_planear` 034a2e63..., `cerebro_fijar_objetivo` d7f33beb..., `_cerebro_op_monto_acordado`
  c85ed2b5... all equal on staging. ROLLBACK-371 carries the live coherence body verbatim.
- Files: `supabase/migrations/371_declaracion_doble.sql`, `ROLLBACK-371-declaracion-doble.sql`, `supabase/staging/assertions/declaracion-doble.sql`.
  New: table `cerebro_declaracion_duda` (RLS on, closed to anon/authenticated), `_cerebro_declaracion_doble(uuid,text)` (no grants), `cerebro_declaracion_pendiente(uuid)`
  (service_role). `cerebro_verificar_coherencia_servicio` only gains the guarded PERFORM after its advisory lock; its answer is unchanged.
- RED: assertion alone on staging before the migration: `ERROR: case 1 plan: expected [25400:recarga/12400;zelle/13000], got [-]`.
- GREEN: migration + assertion in a rolled-back transaction: `ERROR: ALL PASS (rolled back on purpose)`. Mutation checks (each makes the assertion fail): no price
  veto -> case 3; X agreed in an earlier turn accepted -> case 10; no minimum -> case 11.
- Findings while testing: a receipt-only deposit leaves a plain recarga in `incident` (baseline), so cases 16/17 compare with the same operations without the hook.
  Cancelling one planned part leaves a 1-part plan (`_cerebro_reparto_planear` refuses 1 part, so it is only reachable through cancelar); the remaining recarga takes its deposit
  like a recarga that never had a plan (case 16).

### T3 evidence (2026-11-13, staging only)
- `infra/db/staging-migracion.sh aplicar 371... declaracion-doble.sql ROLLBACK-371... cerebro_verificar_coherencia_servicio`: dry-run OK, apply OK, assertion OK,
  rollback OK (md5 igual al previo). Applied md5 of the redefined function 9c4e14b66098; ACLs: hook none, reader service_role, table RLS on.
- `infra/db/staging-migracion.sh relacionadas ... --ya-aplicada ROLLBACK-371` (33 assertions touching the coherence check, planear, repartir, objective, via-quote or the
  log): TOTAL 33 | SAME 33 | DIFF 0. Failing in BOTH base and migration (pre-existing on staging, identical first error): agreed-amount (case 2 second quote),
  bot-mixed-split (cerebro_objetivo_envio_pkey duplicate), cup-excess-equivalent (pg_temp schema), deal-free-beneficiary-writers, deposit-anchor (case 5 needs the
  implicit:cotizar declaration no node writes), grants-mirror-production (crm_registrar_datos_entrega_efectivo missing on staging), objetivo-requiere-compromiso (fixture),
  reparto-destino-node-adapters, zelle-objective-tier, zelle-quote-tier. Every other related assertion passes in both.
- Surface the doubt (NOT applied; n8n/Decisor untouched): in the `Contexto conversacion` query, add after `cerebro_reparto_cuadre(v.id) AS reparto_cuadre`:
  `, cerebro_declaracion_pendiente(v.id) AS declaracion_pendiente` (NULL or {servicio, monto_gyd, servicio_actual, monto_actual_gyd, motivo, creado_at}); the Decisor reads
  `ctx.declaracion_pendiente`. Suggested note: "El cliente pidio {servicio_actual} ({monto_actual_gyd} GYD) y se cotizo {servicio} ({monto_gyd} GYD), pero no esta claro
  que quiera ambos: pregunta al cliente si tambien quiere {servicio}. Si dice que si, llama repartir_envio con ambas partes ({servicio_actual} {monto_actual_gyd},
  {servicio} {monto_gyd}); si no, no registres nada de {servicio}."

- 2026-11-13 T4 production (owner "ok"): previa SEGURO (EQUAL coherence fn, 2 NEW); `OK 371_declaracion_doble 20261113183858`;
  verificar 3/3 equal (9c4e14b6, c0d764e9, 8e0d1bfa). Rollback: ROLLBACK-371.

## Next step
T5.
