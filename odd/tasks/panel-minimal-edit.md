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
- [ ] T1 Shared ✓/X component; replace the 5 copy-pasted pairs and convert the text buttons listed above.
- [ ] T2 Minimalist edit mode for every form in the panel (correction, beneficiary edit, combo edit, add recipient,
  reassign, combo cost, deposit review inputs); app Select everywhere.
- [ ] T3 Staging deploy + owner's look.
- [ ] T4 Production with the owner's go-ahead.

## Progress
- 2026-10-06 document created after mapping.

## Next step
T1.
