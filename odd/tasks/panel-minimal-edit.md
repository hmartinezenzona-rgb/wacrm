# Feature: minimalist edit mode and ✓ / X buttons in the chat operations panel

## Objective
Every "save / confirm a change" and "cancel" button of the chat operations panel is the check (✓) and the X, and the
edit forms stop being big boxed blocks: compact, in place, good-looking in the dark and light themes.

## Owner request (2026-10-06)
"En el panel aún hay botones de guardar y demás que usan letras y la idea es sustituir por la palomita para guardar
algún cambio y la X para cancelar. Lo otro que vi y se ve bien feo es a la hora de editar: salen recuadros feos y
grandes para editar las opciones; eso tenemos que mejorarlo, hacerlo más minimalista pero que se vea bien."

## Map (2026-10-06, src/components/inbox/operations/)
Text buttons to convert:
- remittance-operation-card.tsx ~1052/1055 (BeneficiaryEditFields: cancel, save)
- combo-beneficiary-edit-fields.tsx ~273/276 (cancel, save)
- beneficiary-add-control.tsx ~191/194, 237/240, 325/328 (cancel, add: recharge, combo, generic)
- beneficiary-reassign-control.tsx ~73/76 (cancel, confirmMove)
- combo-cost-field.tsx ~407/411 (cancel, save), ~359 "change" (enter edit: pencil), ~356 "clear" (stays an explicit,
  labelled or trash-icon action with aria-label)
Already ✓/X (copy-pasted pair, 5 places): operation-correction-form.tsx, operation-closing-control.tsx,
deposit-review-section.tsx (force), complete-transfer-section.tsx, complete-transfer-multi-section.tsx.
Stay labelled (workflow actions): completeTransfer.button, closing.closeButton, depositReview.verify/force, banner
retry/completeAnyway, amountMissing link, receipt paging.
Heavy look: wrapper `rounded-md border border-border bg-muted/40 p-2` around each form; each field its own bordered,
filled box with a stacked text-sm label; 5-6 fields stacked full width; native <select> in beneficiary-add-control and
beneficiary-reassign-control; h-10 inputs in deposit-review-section; a separate right-aligned button row.
Tests that find buttons by text: remittance-operation-card.test.tsx (buttonByText save/cancel, and a className
assertion on InlineEditField's border at ~1655), combo-cost-field.test.tsx, beneficiary-add-control.test.tsx (~290),
beneficiary-reassign-control.test.tsx (~56), operations-panel-container.test.tsx (~400).

## Design (Claude, stated to the owner)
- One shared component (e.g. ConfirmCancelButtons, next to notify-toggle.tsx) used everywhere: X then ✓ on the right;
  ghost icon buttons, X muted, ✓ green (emerald text, no solid fill), aria-label + title from the existing catalog
  keys, icons aria-hidden, disabled + visible pending cue, visible focus ring, hit area >= 32px.
- No outer filled box: the edit area sits in place in the card with at most a thin left rule (border-l-2) and
  space-y-1.
- Fields: borderless rows with a subtle bottom border (border-b border-input), transparent background, h-8, text-sm,
  focus ring; the same height across the panel (deposit review included).
- Labels: small muted text (text-[11px] text-muted-foreground) to the LEFT of the field on a grid, or the existing
  leading icon + aria-label (InlineEditField); short fields side by side (currency + amount).
- Every dropdown is the app's Select (no native <select>).
- Enter saves, Escape cancels (keep where it exists, add where missing).
- No behaviour change: same fields, validation, commands, errors, permissions.

## Scope
App only (src/components/inbox/operations/** and its tests, catalog keys only if a label is missing). No DB, no bot.

## Constraints
- Accessibility: every icon-only button has aria-label and title; contrast 4.5:1 for text; focus visible.
- Production only with the owner's go-ahead, after the owner's look on staging.

## TDD
Strict TDD on. Runner: vitest. Tests move from text queries to aria-label queries first (RED), then the components.
The app's Select (Base UI) hangs under jsdom: mock "@/components/ui/select" with a native double as
operation-correction-form.test.tsx does.

## Tasks
- [x] T1 Shared ✓/X component; replace the 5 copy-pasted pairs and convert the text buttons listed above.
- [x] T2 Minimalist edit mode for every form in the panel (correction, beneficiary edit, combo edit, add recipient,
  reassign, combo cost, deposit review inputs); app Select everywhere.
- [ ] T3 Staging deploy + owner's look.
- [ ] T4 Production with the owner's go-ahead.

## Progress
- 2026-10-06 document created after mapping.
- 2026-10-06 T1 + T2 implemented together (one commit: the forms mix both changes in the same files, so a T1-only commit
  would not be a green state). Browser look NOT verified (no browser available to the writer): owner's look pending in T3.

## Evidence (T1 + T2)
- RED first: tests moved to aria-label queries, the InlineEditField class assertion moved to the underline look, shared
  component test added -> `vitest run src/components/inbox/operations`: 46 failed (components still rendered text buttons / boxes).
- GREEN after implementation: `vitest run src/components/inbox/operations src/i18n --testTimeout=20000`: 27 files, 419 tests pass.
- Full `npx vitest run --testTimeout=20000`: 165 files, 2078 tests pass. `npx tsc --noEmit -p .`: no errors.
  `npx eslint src/components/inbox/operations`: no errors, no warnings.
- grep: no `<select` / `<option` left in src/components/inbox/operations (non-test); the save / cancel / add / confirmMove /
  comboCost change+clear catalog keys are only used as aria-label / title.

## Final look (per form)
Shared: `confirm-cancel-buttons.tsx` (X muted, then check emerald, ghost size-8 icon buttons, aria-label + title, spinner
while pending, `type="submit"` for forms, children slot for the bell) and `cancelOnEscape` (Escape in a field cancels;
portaled Select popups keep their own Escape). `edit-form-fields.tsx`: underline field (transparent, border-b border-input,
h-8, text-sm, rule turns ring colour on focus + soft ring), `FieldRow` (11px muted label left, grid 5.5rem/1fr),
`FieldPair` (two short fields side by side, label on top), `EDIT_AREA` (border-l-2 border-border pl-2, space-y-1).
- Correction form: service Select row, pair (quoted source | quoted destination), rows currency / delivery / deposit; error
  left and check/X right on one last row. Select with the underline trigger.
- Beneficiary edit (card + combo): InlineEditField lost its filled box (bottom rule only); check/X right below, Enter saves,
  Escape cancels (existing).
- Add recipient: recharge/saldo = one phone row; combo = five rows + amount (GYD) + hint; card/zelle = type Select row, the
  type fields, pair (amount | currency). Check is labelled with the add key.
- Reassign: one Select row (app Select) + check (confirmMove label) locked until a target is chosen.
- Combo cost: saved value row with pencil (change) and trash (clear) icon buttons; edit = one label+input row with check,
  and X only when a cost already exists; Escape cancels.
- Deposit review: inputs h-10 -> h-8 underline rows with left labels; force confirm = check/X + bell in a left-ruled area.
- Closing control, complete-transfer (single, multi): same check/X component; closing control lost its box.
- 2026-10-06 T3 staging deployed (owner's look pending; T3 NOT checked off): release eb35591020666e9688f24f3e00e1b6ae9ac5c54e,
  BUILD_ID ajGFFfqB6tsxrfdNJNy7k, same procedure as 438c001 (clean prod-build, docker node:20 uid 1000, staging-build.env with
  NEXT_PUBLIC_APP_LOCALE=es, unchanged). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production refs /
  32 staging files, sha256 OK. `current` -> eb35591, `anterior` -> 438c001; pm2 wacrm-staging cwd resolves to the new release,
  restarts 71 -> 72 and stable; crm.onlinefreedom.site/login 200 with the new BUILD_ID and "Bienvenido de nuevo"; prod-build clean.
  No DB change (migration 223 already on staging). Production not touched.
  Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/438c0017274593e61dee836d53ef6cfd29a031e2 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`

## Deviations
- One commit for T1+T2 (see Progress).
- Deposit review inputs have no Enter-to-verify (verify is a workflow action with a labelled button; not an edit form).
- NotifyToggle keeps its size-7 hit area (the 32px rule applied to the check/X).
- Complete-transfer sections keep their outer bordered card (not in the map's "heavy look" list); they gained Escape.

## Next step
T3 staging deploy + owner's look.

## Owner look on staging (2026-10-07, release eb35591)
"Se ve mejor, pero las opciones a editar las veo redundantes en algunos casos: si selecciono Zelle o cualquier otro
servicio, la moneda de destino ya la dice el servicio, y el método de entrega también me parece redundante; esos pasos
por defecto deben llenarse cuando uno selecciona el servicio. Si tengo 26 mil GYD y cambio a otro servicio, el monto de
destino debe recalcularse a la tasa del servicio seleccionado, si aplica. Veo opciones como cuban card, zelle, clásica,
etc.: ahí falta el tropical, y en vez de cuban card usar CUP. Está un poco confuso."
(Note: the first look failed because staging had no OPEN operation; one was created, 094eb6d6.)

- [x] T2b Simplify the operation correction form (pencil):
  - Fields: Servicio (select); Deposit (GYD) and Destination amount side by side; Deposit method. Remove the
    "destination currency" and "delivery method" inputs: the service sets both (crm_cambiar_servicio already does).
  - The destination amount shows its currency as a read-only suffix (USD / CUP / SM ...) taken from the selected
    service, and is recalculated when the service or the deposit changes, with that service's rate (CUP rate, single
    USD rate, Zelle tiers, cash rate); a value typed by the person wins. Services without a destination quote
    (recarga, saldo, combo, visa) hide the destination amount.
  - Naming: the CUP rail reads "CUP" (not "cuban card" / "Tarjeta cubana") everywhere in the panel, en and es;
    Tropical present in every service/recipient list of the panel.
  - No raw internal values (cuban_card, efectivo_usd ...) visible anywhere in the panel.

## Evidence (T2b, 2026-10-07)
- RED first: 11 new correction-form tests failed (fields still there, no suffix/hide/recalc, old labels); GREEN after the form,
  `destination-quote.ts` and the catalog change. `tsc --noEmit` clean, eslint clean on operations + remittance-operations,
  full `vitest run --testTimeout=20000`: 166 files, 2101 tests pass. App-only: NO DB change.
- Rates path taken: the form reads the current rates from the existing `GET /api/calculator/rates` (requireRole viewer, so any
  agent) through the new `fetchCalculatorRates()` in commands.ts, and previews with the TypeScript mirror
  (`deriveAmountFromDeposit`) via `src/lib/remittance-operations/destination-quote.ts`. If rates are missing or the read fails,
  the field shows the muted placeholder "Recalculated on save" / "Se recalcula al guardar" and the DB value stands.
- Destination amount is sent to corregirOperacion ONLY when typed (or, see below, when a manual lock would freeze a stale one).
  destination_currency and delivery_method are never sent from the form (the service sets them via cambiarServicio).
- Deposit-only change: trigger trg_zz_recalc_destino_operations (AFTER UPDATE OF quoted_source_amount) recomputes the destination
  when it is not locked and its origin is 'calculated'. If an earlier manual correction left a lock on quoted_destination_amount,
  the DB would keep the stale amount; the form then sends the recalculation it shows (only when rates are available). Without
  rates in that case the stale amount stays: open point.
- Naming: closing.method.cuban_card = "CUP" (en/es), beneficiaryType.cuban_card = "CUP card" / "Tarjeta CUP"; the dashboard queue
  already says CUP. Labels renamed "Deposit (GYD)" / "Destination amount" (es "Depósito (GYD)" / "Monto de destino").
- Tropical / lists audit: Tropical was missing only in the removed free-text delivery-method field. OPERATION_SERVICES, closing
  control SERVICES, ADDABLE_BENEFICIARY_TYPES and the beneficiaryType catalog all include it. No datalist/autocomplete/suggestion
  list exists in the panel; the beneficiary edit/add forms do not edit delivery_method. Closing-control picker: cuban_card and
  zelle use MethodIcon (card / "Z" icons), the others PICKER_ICON, so all render. ADDABLE_BENEFICIARY_TYPES deliberately has no
  efectivo_usd/recarga/combo/visa/saldo (recharge/combo have their own add forms). KNOWN_BENEFICIARY_TYPES gained visa and saldo
  so they no longer fall to the raw-value fallback; the only raw fallback left is a free-form deposit/delivery value outside the
  catalog (e.g. "bank").
- Not verified: no browser available (look and suffix layout unseen), no staging run.
- 2026-10-07 T2b staging deployed (owner's look pending; T3 NOT checked off): release 0c6c0e23b446fbb9a3c317123024183b5a042096
  (0c6c0e2), BUILD_ID HtlXkuWME5Ju0BhbM729t, same procedure as eb35591 (clean prod-build, docker node:20 uid 1000,
  staging-build.env with NEXT_PUBLIC_APP_LOCALE=es, unchanged). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests
  passed, 0 production refs / 32 staging files, sha256 OK, "Se recalcula al guardar" present in .next/server. `current` -> 0c6c0e2,
  `anterior` -> eb35591; pm2 wacrm-staging restart count 72 -> 73, stable after; /login 200 with the new BUILD_ID and
  "Bienvenido de nuevo". No DB change. Production not touched.
  Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/eb35591020666e9688f24f3e00e1b6ae9ac5c54e ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`

## Owner look on staging (2026-10-07, release 0c6c0e2): "al poner zelle no se recalcula"
Cause (staging op 094eb6d6): crm_calcular_monto_destino (217) quotes only when the operation has exactly ONE vigente
recipient. crm_cambiar_servicio to zelle retires the card, so the operation has no recipient and its destination stays
NULL (and stays NULL when switched back to CUP, the card being gone). The form preview is right; the stored quote is not.

- [x] T2c DB migration 224 (+ ROLLBACK-224, staging first): with NO vigente recipient and a known rail
  (delivery_method cuban_card / zelle / clasica / tropical / efectivo_usd, service_type remesa, GYD source, open
  operation), crm_calcular_monto_destino quotes from the operation's rail with the same rules as the single-recipient
  case (Zelle through cerebro_zelle_cotizar_op, USD single rate, cash rate, CUP rate; whole USD rounded down).
  Unchanged: one recipient (as today), several recipients (cleared / reparto rules), manual locks, closed
  operations, non-GYD sources, recarga/saldo/combo/visa.

## Evidence (T2c, 2026-10-07) - NOT applied, waiting for one decision
- RED first: supabase/staging/assertions/quote-from-rail.sql on staging before 224 fails at line 99, case a1 ("zelle with no
  recipient must be quoted 100 USD at 260 (calculated), got -/-/-/-").
- Migration 224_quote_from_rail.sql + ROLLBACK-224-quote-from-rail.sql written. crm_calcular_monto_destino: v_rail = the lone
  recipient's type, or with no recipient the operation's delivery_method (same branch, same helpers and rounding); recipient
  amounts still written only with exactly one recipient. Trigger trg_zz_recalc_destino_operations now also fires on UPDATE OF
  delivery_method, service_type: the bot (cerebro_marcar_destino_usd) sets the rail without touching the deposit and never calls
  crm_cambiar_servicio, so a call from crm_cambiar_servicio alone would leave case g unfixed. Pre-224 md5 (staging):
  crm_calcular_monto_destino cbd256e4d22bcc34a1a5c604d2311c02, crm_cambiar_servicio ee82240e976cd036b8b23b085c8d8ca9 (unchanged),
  cerebro_marcar_destino_usd f239d898e9533b82a9822f4eb98ee6e7 (unchanged), remittance_operations_recalc_destino_trigger
  064eb2b54c8c70f48d1cec68c9a8c35d (unchanged). Round trip in one rolled-back transaction: 224 changes 1 function, ROLLBACK
  restores 4 of 4 md5s and the trigger definition.
- GREEN (224 applied inside a rolled-back transaction, staging NOT changed): quote-from-rail passes all cases (a-g), as is and
  with promos discarded. Regressions run the same way, as is and no promo: all listed assertions pass EXCEPT one conflict:
  change-operation-service.sql case a4 (the zelle switch asserts "no recipient and no destination", i.e. exactly the bug).
  It fails identically with and without promos ("got n=0 / zelle / 20 / USD"). The existing expectation was NOT edited.
- Real apply to staging and the check of operation 094eb6d6 are pending that decision.

- 2026-10-07 T2c applied on staging by the parent (the writer stopped, correctly, on an existing expectation):
  - change-operation-service.sql cases a4 (-> zelle) and c (zelle -> cuban_card) asserted "no recipient => no
    destination". The owner asked for exactly the opposite ("al poner zelle no se recalcula"), so both now expect the
    rail quote (Zelle tier quote of the deposit / the deposit at the CUP rate, origin calculated). No other expectation
    changed.
  - Applied for real: schema_migrations 224 224_quote_from_rail; crm_calcular_monto_destino md5 after
    2fd07252c7a6b229cc95b84965c3e944 (pre cbd256e4d22bcc34a1a5c604d2311c02, in the ROLLBACK header).
  - After the apply, as is: quote-from-rail, change-operation-service (also with no promo), destination-amount (11),
    rounding-parity (6), deterministic-usd-destination, clasica-card-from-delivery-method, zelle-tiered-rate,
    zelle-tier-prices, zelle-objective-tier, zelle-quote-tier, zelle-remainder-amount, reparto-guards, reparto-auto
    (13 PASS), reparto-keeps-zelle, reparto-usd-card-rail (5 PASS), split-deposit-minimums, requested-amount-target
    (+helpers), corrections (10), saldo-model, recarga-model, combo-model, visa-model, operations-board, read-rpc: all pass.
  - Staging operation 094eb6d6 (zelle, 26,000 GYD, no recipient): recomputed once by hand (existing rows are not
    touched by the migration): 100 USD at 260, origin calculated.

## Owner look on staging (2026-10-07): cash USD recipient cannot be added
"Elegí efectivo USD y a la hora de agregar beneficiario no me sale para agregar el USD en efectivo, solo sale Zelle,
Clásica, Tropical y tarjeta Cuba; no sale para agregar los datos que se piden en la entrega de USD cash. Ahí deberían
poder llenarse."
Cause: ADDABLE_BENEFICIARY_TYPES (beneficiary-add-control.tsx) has no efectivo_usd, and crm_agregar_beneficiario
(newest 223) refuses it (accepted: cuban_card, zelle, clasica, tropical, multiple_distribution, recarga, combo; address
only for combo). Only the bot can create a cash recipient today.

- [x] T2d Add a cash USD recipient from the panel:
  - DB migration 225 (+ ROLLBACK-225, staging first): crm_agregar_beneficiario accepts efectivo_usd with the data the
    cash delivery needs (the same fields the bot's cash path stores and crm_corregir_beneficiario already edits for
    efectivo_usd: name, phone, address ... — take the model from the cash service migrations 137/188 and the bot
    writer), same validations as the bot path, amount computed by the existing calculation.
  - App: the "add recipient" form follows the operation's service: when the operation already has a service
    (cuban_card, zelle, clasica, tropical, efectivo_usd) it shows that service's fields directly, with no type picker;
    the picker appears only when the operation has no service yet. Cash form with its fields; minimalist look; ✓ / X.

## Evidence (T2d, DB, 2026-10-07)
Cash recipient model found (bot writer `crm_registrar_datos_entrega_efectivo`, 150/191; completeness 188):
- Row: `beneficiary_type = efectivo_usd`, columns `name` (optional, 191), `phone`, `address`, `id_photo_wamid` (the WhatsApp
  message id of the ID-card photo; the image stays in `messages.media_url`). No card, no Zelle account. One vigente cash row
  per operation (the bot replaces it on every change), only on an operation whose `delivery_method = efectivo_usd`.
- Complete (`crm_beneficiarios_completos`): phone AND address AND `id_photo_wamid` all non-blank. Name is not required.
- Priced by the existing calculation: `floor(deposit / crm_tasa_vigente('efectivo')) USD` (staging 290: 30,000 GYD -> 103);
  minimum `cerebro_minimo_efectivo_gyd()` = 100 USD x cash rate (29,000 on staging). The add path never checked the minimum.
- `crm_corregir_beneficiario` (212) lets address be edited on a cash row; nobody can set the photo from the panel.
Decisions (migration 225, crm_agregar_beneficiario only):
- Accepts efectivo_usd with `name` (optional), `phone` (required, digits, a +53 prefix on 10 digits dropped like a combo's, 8-15
  digits) and `address` (required). Refuses any other key (amount, currency, card_number, zelle_account, delivery_method,
  reference, contact_phone): the amount is calculated, not given. A panel-added recipient stays incomplete until the customer's
  ID photo arrives through the chat (same as the bot path, which also needs the photo).
- Required fields follow the completeness rule minus the photo (the panel cannot supply it); the bot path itself accepts
  partial data and merges, but a half-empty panel row would be useless, so phone and address are required here.
- Second cash recipient refused (22023): the bot keeps one. Cash refused on an operation whose rail is another one
  (zelle ...), allowed when it has no rail yet (like the other types); combo / recarga / saldo operations are already refused
  by the existing rules. The existing add path has NO rule against a card/Zelle recipient on a cash operation (nor the
  reverse): left as is, not invented.
- Amount/currency: the recipient triggers price the operation and the lone recipient; when an earlier correction locked the
  recipients the function copies the calculated quote to the recipient (as crm_cambiar_servicio does) and releases the
  calculation's own destination locks. Same `beneficiaries` lock and one `human_beneficiary_added` audit row as the others.
- RED first: `supabase/staging/assertions/cash-recipient-add.sql` on staging before 225 fails at its first add
  ("invalid beneficiary_type: efectivo_usd", case a).
- Migration 225_cash_recipient_add.sql + ROLLBACK-225-cash-recipient-add.sql (pre-225 md5 of crm_agregar_beneficiario
  a7dfae5d96716f2111af6cc548d96f39 in the header). Round trip in one rolled-back transaction: 225 changes 1 function,
  ROLLBACK restores 350 of 350 public functions. Applied for real on staging: schema_migrations 225 225_cash_recipient_add;
  md5 after ee9da2d6f824114674da9355eff122ce; grants unchanged (anon no, authenticated yes).
- GREEN with 225 (rolled back, then again after the real apply), as is and with promos discarded: cash-recipient-add (all
  cases a-g) and the regressions add-beneficiary, change-operation-service, quote-from-rail, combo-model, recarga-model,
  saldo-model, corrections, destination-amount, calculator-cash, cash-delivery-activation, cash-delivery-data,
  cash-delivery-rate, cash-phone-not-a-card, panel-cash-recipient, panel-notify-and-cash-name, panel-quote, service-catalog,
  combo-edit, manual-close-service, ultima-cotizacion. Leftovers 0 (contacts, operations, wamid rows).

## Evidence (T2d, app, 2026-10-07)
- RED first: new tests in beneficiary-add-control.test.tsx and remittance-operation-card.test.tsx -> 17 failed (no `service` prop, no
  cash form, picker without Cash USD). GREEN after the change; `tsc --noEmit` clean, eslint clean on src/components/inbox/operations,
  `vitest run src/components/inbox/operations src/i18n --testTimeout=20000`: 27 files, 454 tests; full suite: 166 files, 2119 tests.
- `BeneficiaryAddControl` takes `service` (card passes `currentServiceOf(operation)`). cuban_card / zelle / clasica / tropical /
  efectivo_usd -> that service's fields directly, no picker; no service yet -> the picker, now with Cash USD (5 types). Recarga, saldo
  and combo keep their own forms (decided by `serviceType`, ahead of `service`).
- Cash form: name (optional), phone, address, a one-line hint "The ID photo comes from the chat" (`cashIdPhotoHint`, en/es), same
  underline FieldRow + ConfirmCancelButtons, Enter saves (form submit), Escape cancels. Sends `{beneficiary_type: efectivo_usd,
  phone, address[, name]}` only; phone digits 8-15 and a non-blank address are checked before the request. No amount/currency field:
  the DB calculates it. The other add forms (card, Zelle, clasica, tropical) still ask for amount + currency because
  crm_agregar_beneficiario requires them for those types; unchanged.
- The "add recipient" button is hidden once the operation has its cash recipient (the DB refuses a second one).
- Not verified: no browser available (look unseen). Staging app release NOT deployed by this task.
- Open points: the edit form of an existing cash recipient (BeneficiaryEditFields) still shows the card field and no address/name,
  so a cash recipient's address cannot be corrected from the panel yet even though crm_corregir_beneficiario accepts it; the
  panel cannot attach the ID photo (comes from the chat). Card/Zelle add forms do not prefill the currency from the service.

- [x] T2e Close the T2d gaps (app only, no DB change):
  - The recipient edit form follows the recipient's TYPE; a cash recipient is editable (name, phone, address) and shows the
    ID photo note. The card and Zelle add forms derive the currency from the service and prefill the amount from the quote.

## Evidence (T2e, 2026-10-07)
- RED first: new edit-form tests failed against the original card component (4 failed: cash showed card field, no
  name/address); add-control tests failed (no `quote` prop, currency field still asked, 10 failed). GREEN after: `tsc` clean,
  eslint clean on src/components/inbox/operations, `vitest run src/components/inbox/operations src/i18n`: 27 files, 472 tests;
  full suite: 166 files, 2137 tests.
- Field table (checked against crm_corregir_beneficiario 212 and crm_agregar_beneficiario 225):
  | type | edit form | add form |
  | efectivo_usd | name (optional, clearable -> null), phone, address; ID photo note | name (optional), phone, address; note |
  | zelle | name, Zelle account (+ amount when 2+ recipients) | name, Zelle account, amount (USD) |
  | cuban_card (CUP) | card, phone | card, phone (optional), amount (CUP) |
  | clasica / tropical | card, phone | card, phone (optional), amount (USD) |
  | recarga / saldo | phone only | phone only |
  | combo | its own editor (unchanged) | its own form (unchanged) |
- RPC rules: address accepted only for combo and efectivo_usd (hidden elsewhere); the cash row can never get card/Zelle keys;
  name/phone/address sent only when changed; phone 8-15 digits; phone and address cannot be emptied on a cash row (same as add).
  Nothing the RPC refuses blocked a field.
- Add forms: crm_agregar_beneficiario STILL REQUIRES amount and currency for cuban_card/zelle/clasica/tropical (225, lines
  243-253), so both are sent. The currency is derived from the service/picked type (cuban_card CUP; zelle, clasica, tropical USD)
  and shown in the amount label, no field. The amount is prefilled with the operation's quoted destination amount only when the
  operation has no recipient yet (the one being added is the lone one) and the quote's currency equals the service's; editable.
  With 1+ recipients the quote is split, so the amount is left empty.
- Read view already showed cash name, phone, address (MapPin) and the ID photo link / "ID photo missing" with catalog labels; no change.
- Not verified: no browser (look unseen); staging app not deployed by this task.
- 2026-10-07 T2d staging deployed (owner's look pending; T3 NOT checked off): release 31529b8b262f8e1096f2eeae9202c9a6d3b7b9c2,
  BUILD_ID v7KAHODid57XwZHNvHxkc, same procedure as before (clean prod-build, docker node:20 uid 1000, staging-build.env with
  NEXT_PUBLIC_APP_LOCALE=es, unchanged). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production refs,
  sha256 OK; `current` -> 31529b8, `anterior` -> 0c6c0e2; /login 200 with the new BUILD_ID. Migrations 223-225 on staging.
  Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/0c6c0e23b446fbb9a3c317123024183b5a042096 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`
- 2026-10-07 T2e staging deployed (owner's look pending; T3 NOT checked off): release 6e97fd24379e85bc02f1ce94be1f3c7104dcc1ea,
  BUILD_ID eDh46vb6sbxun9VIawU6n, same procedure. Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production
  refs / 32 staging files, sha256 OK. `current` -> 6e97fd2, `anterior` -> 31529b8; pm2 wacrm-staging cwd resolves to the new release,
  restarts 74 -> 75 and stable; crm.onlinefreedom.site/login 200 with the new BUILD_ID and "Bienvenido de nuevo"; prod-build clean.
  No DB change. Production not touched.
  Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/31529b8b262f8e1096f2eeae9202c9a6d3b7b9c2 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`

- 2026-10-07 owner (staging 6e97fd2): "este texto que sale abarca mucho espacio, quítalo" (the service-change note
  "Se recalcula la cotización y se quitan los destinatarios..."). Removed from the correction form and from both
  catalogs (serviceChange.warning). RED: the form test now forbids any explanatory text when another service is chosen
  (1 failed); GREEN: operations panel + i18n 27 files / 472 tests, tsc and eslint clean.
