# HANDOFF for the eliminate-deals work: production changed under you (2026-10-01)

Read before deploying 160 / 167_operation_incident_reason / any deal-free `cerebro_registrar_deposito`
to production. Also recorded in Engram #343 (topic `eliminate-deals/registrar-conflict`).

## What is live in production (applied at the owner's request, production directly)
| Migration in production | Commit | Touches |
|---|---|---|
| `168_late_mmg_email_recross` | `0b4fcab` | pg_cron job `recruzar-depositos-tardios` (every minute) -> `cerebro_recruzar_depositos_tardios()`; audit action `automation_late_deposit_verification` added to `remittance_admin_audit_action_chk`; notify workflow `wGud0KGR6eMqqfMQ` ("Leer secreto") treats it as a verification |
| `170_split_deposit_minimums` | `369eff6` | new `cerebro_minimo_gyd`, `cerebro_objetivo_minimo`, `cerebro_cruzar_pendientes`; **`cerebro_registrar_deposito` rewritten** (sum branch reads `remittance_operations.status`, not `deals.stage_id`; objetivo = service minimum; crosses earlier uncrossed receipts); late job generalised to multi-receipt operations; config keys `minimo_gyd_*`, `completar_ventana_horas` |
| `171_requested_amount_target` | `2c20505` | table `cerebro_cotizacion`; trigger `trg_registrar_cotizacion` AFTER INSERT on `messages`; `cerebro_monto_cotizado`, `cerebro_cotizacion_vigente`, `cerebro_aplicar_cotizacion`; `cerebro_objetivo_minimo` redefined (quote is the target) |

Production's `cerebro_registrar_deposito` is now 170's body (prosrc md5 `41cb61bbe9609af21c50bb965d69501f`),
not 125's (`a0251d99...`) and not the `314abaa0...` the eliminate-deals doc measured.

## What the deal-free work must do
1. Rebuild the deal-free `cerebro_registrar_deposito` (160 / 167) on production's LIVE body, keeping
   170's sum branch, the `cerebro_objetivo_minimo` calls and the `cerebro_cruzar_pendientes` call.
   `cerebro_cruzar_pendientes` and `cerebro_recruzar_depositos_tardios` still read `deals.notes`
   ("DEPOSITO: <amount>", "Ref: <digits>" per `---` block): they need a deal-free source too.
   `cerebro_objetivo_envio` / `cerebro_saldo_envio` are keyed by `deal_id`.
2. Re-run, self-reverting, against the target database:
   `supabase/staging/assertions/split-deposit-minimums.sql` (5 cases) and
   `supabase/staging/assertions/requested-amount-target.sql` (6 cases; needs the helpers of the first).
3. Duplicate migration numbers on this branch: 168 (`late_mmg_email_recross` in production /
   `tags_off_delivered_operations`) and 171 (`requested_amount_target` in production /
   `operations_realtime_publication`). The production ones are applied under those names; renumber
   the ones that are not in production yet.

Also live since: `173_target_origin_label` (commit fa769f4): `cerebro_riel_op`, `cerebro_minimo_gyd` and
`cerebro_objetivo_minimo` redefined; `cerebro_objetivo_envio.pedido` is now 'cotizacion' | 'minimo <via>'
and the Cerebro node `Cruzar deposito con MMG` reads it (keyed by deal_id). Your 172 exists, so this is 173.

Also live since: `174_reparto_tool_usd_rail` (commit ccfb082) + Cerebro version 177e5713: the tool
`registrar_reparto_multiple` now passes each share WITH its currency in the same 11 arguments ("45000 CUP"
or "30 USD clasica|tropical"; a bare "30 USD" takes cerebro_destino_pendiente, none -> error) and writes
"Recibe: 30 USD Clasica" in the block; `cerebro_parsear_beneficiarios` reads it as a clasica/tropical row
in USD; `cerebro_detectar_destino` accepts plurals. Your 163 `cerebro_registrar_reparto_multiple` must accept
these values (it currently strips everything but digits and writes CUP).

Also live: `175_reparto_keeps_zelle`: `cerebro_sync_beneficiarios` keeps the remesa's latest Zelle block
vigente when the newest block is a card reparto (user decision 2026-10-01). Your deal-free writers (162/163)
must keep that rule.

Also live: `176_zelle_remainder_amount`: `crm_calcular_monto_destino` (157 body + one call) runs
`crm_monto_resto_zelle(op)`: a vigente Zelle without amount next to priced shares gets
floor((deposit or quote - CUP shares/CUP rate - USD shares x USD rate) / USD rate), amount_origin 'calculated'.

Also live: `177_panel_can_verify_by_status`: `crm_comprobantes_de_operacion` offers verify/force when the
operation status is `deposit_verification` or `incident` (it no longer reads the stale `deals.stage_id`).

Also live: `178_repeated_receipt` (prosrc md5 registrar `0637aba3...`, cruzar_depositos `0050acb1...`) + Cerebro
version 0d7de989 (`Snapshot final` drops a repeated Ref+amount+currency inside one burst):
`cerebro_registrar_deposito` returns the open envio that already holds the receipt's Ref ('ya registrado (misma
referencia)', appends a COMPROBANTE REPETIDO line, never sums it); `cerebro_cruzar_depositos` collapses repeated
Ref+amount pairs and, when every Ref is already consumed by this envio, reports its state and writes nothing.
Your deal-free registrar must keep the Ref lookup (it reads `deals.notes` today). Guard:
`supabase/staging/assertions/repeated-receipt.sql` (needs the helpers of split-deposit-minimums.sql).

Also live (n8n only, 2026-10-01, Cerebro version a2b2851d): `Contexto conversacion` returns a new column
`beneficiarios_registrados` (vigente beneficiaries of the open operations); the Decisor and the agent prompt
use it. Details: `odd/tasks/tool-reliability-test.md`.

None of 168/170/171/173/174/175/176/177/178 is on staging. Feature doc: `odd/tasks/split-deposit-minimums.md`.
