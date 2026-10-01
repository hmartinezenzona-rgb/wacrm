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

None of 168/170/171 is on staging. Feature doc: `odd/tasks/split-deposit-minimums.md`.
