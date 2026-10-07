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

- [ ] T2c DB migration 224 (+ ROLLBACK-224, staging first): with NO vigente recipient and a known rail
  (delivery_method cuban_card / zelle / clasica / tropical / efectivo_usd, service_type remesa, GYD source, open
  operation), crm_calcular_monto_destino quotes from the operation's rail with the same rules as the single-recipient
  case (Zelle through cerebro_zelle_cotizar_op, USD single rate, cash rate, CUP rate; whole USD rounded down).
  Unchanged: one recipient (as today), several recipients (cleared / reparto rules), manual locks, closed
  operations, non-GYD sources, recarga/saldo/combo/visa.
