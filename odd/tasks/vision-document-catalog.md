# Feature: vision knows the exact layout of every document the business uses

## Objective
The bot's vision reads every deposit receipt format (and every other document we use: Cuban cards, Zelle accounts, ID
cards) reliably, including the uncommon ones, by describing each real layout to it.

## Problem (owner, 2026-10-03)
MMG receipts have defined structures, but the owner has seen several deposit formats the bot does not read well.
Today the vision prompt (gpt-4o, 4 readings incl. rotated) describes three MMG layouts: (A) Name / Transaction ID /
Receiver Number / Payment, (B) app "Transaction Details" (negative amount), (C) printed paper receipt "An amount of ...
is credited to ..." with the numbers that are NOT the reference. Any other layout is guessed. The ID card case (A7,
gate87) showed that describing a document's structure fixes its recognition.

## Scope (authorized by the owner, 2026-10-03, after the cash work)
Catalog the real formats from history, describe the missing ones in the vision prompt, add a reference image only for
formats text cannot pin down, and measure before/after on past images.

## Tasks
- [x] V0 Catalog: collect customer images with the vision verdict and the outcome; select the misreads (receipts
      classified "otro", wrong amount or reference, receipts that ended in incidents such as sin_correo / mismatch);
      group them by layout. Show the owner the groups (one example each).
- [ ] V1 Owner confirms which groups are real deposit formats (and any other document types worth adding).
- [ ] V2 Replay baseline: run the current vision over the catalog (gate83-replay / gate87-probar-vision style harness)
      and record the hit rate per format.
- [ ] V3 Describe each new format in the prompt (fields, where the amount and the reference are, numbers to ignore);
      for formats text cannot fix, try one reference image and weigh the cost per reading.
- [ ] V4 Replay again: new formats read correctly, old formats unchanged; then staging live test and production with
      the owner's go-ahead (script with backup, all four vision nodes).

## Constraints
Customer images are private: kept local/scratch, never published; the owner sees only the examples he asks for.
Changes by script on staging first; production with go-ahead.

## Acceptance criteria
Every catalogued format is read with the right amount and reference in the replay; no regression on A/B/C.

## Progress / evidence
- 2026-10-03: feature document created from the owner's request; starts after the cash work
  (odd/tasks/remesa-closing-and-cash.md plan P1, P2, A8).
- V0 (2026-10-03, production data): cerebro_lecturas_vision holds every vision reading since 2026-09-28: 78 readings
  (50 receipts, 23 Cuban cards, 1 Zelle account, 4 "otro"). Receipts: 46 match their MMG email exactly, 0 with a wrong
  amount, 4 references not found — 1 is Bruce's misread resend (task C), and 3 are misreads with a matching email of
  the same amount a minute earlier: 09-29 17:46 one digit 5->3 (agent app "Successfully Completed!" screen, clear, the
  180-degree reading won the shape tie-break), 10-02 12:41 two neighbours swapped 78<->87 (format C photographed from a
  monitor, tilted), 10-02 12:08 badly read (format C photographed from a monitor, heavy moiré). All three were
  force-verified by hand and their real emails were left unconsumed. "otro": the ID cards (now A7) and Bruce's MMG
  account screenshot. CONCLUSION (owner told): the formats are known; the failures are digit accuracy on photos of
  screens. Plan changed from "describe more formats" to a safety net on the MMG emails.
  - Owner go-ahead (2026-10-03): linked the 3 real emails to their completed operations in production
    (20401883358716 -> 57a7ada2, 10402122268980 -> b6eeb07b, 10402124277872 -> 703f1a13; consumido_en + operation_id,
    only if unconsumed and same amount; audited human_correction).
  - Timing: the 12:08 email row was created 9 s AFTER the reading; 12:41 30 s before; 09-29 1 s before.
  - DB 197 (staging, ee2e51d): cerebro_ref_parecida (8+ digits, lengths +-1, optimal string alignment distance <= 2);
    cerebro_cruzar_deposito's approximate match uses it instead of "same length, first 5, last 4" (all other guards
    kept: amount, unconsumed, not voided, window, ONE candidate, CRUCE_APROXIMADO admin alert); cerebro_cruzar_pendientes
    and cerebro_recruzar_depositos_tardios also take a similar reference of the same amount (late email). Assertion
    cruce-ref-parecida.sql (rule cases, swap at receipt time, two candidates refused, late pairing via
    cerebro_cruzar_pendientes, exact unchanged) RED -> GREEN; the case-4 fixture first collided with case 3's similar
    emails of the same amount and was refused as ambiguous — the uniqueness guard at work. Cross regressions: cutover,
    deal-free-money-rules, deposit-path-without-deals ALL PASS; deposit-review, n8n-repoint, verify-deposit-status-drift
    (deal fixtures), operation-incident-reason, repeated-receipt and split-deposit-minimums fail the same before and
    after 197 (pre-existing).
  - Rotation tie-break NOT changed: it was measured on 60 real images and favours the shape score; the 09-29 case is
    covered by 197 (a one-digit-off elected reading still pairs). Revisit only with a replay.
  - Still open: the 10-02 12:08 kind (badly read monitor photo) stays a manual verification; the bot's "No me llegó
    bien la imagen" reply to a readable non-receipt image.
  Next: owner go-ahead for 197 in production; then panel-other-services.md (recargas).
- 197 PRODUCTION (2026-10-03 ~20:30 UTC, owner go-ahead): md5 of cerebro_cruzar_deposito / cerebro_cruzar_pendientes /
  cerebro_recruzar_depositos_tardios in production = staging pre-197; cerebro_ref_parecida absent; backup
  produccion-20261003T202532Z.dump; gate93-aplicar-db.py ensayo "parecida=true lejana=false open_ops=7" rolled back,
  aplicar {"r":"ok"}, registered; cruce-ref-parecida, deal-free-money-rules ALL PASS, deposit-path-without-deals passes
  (NOTICE form); helper dropped, 0 fixture contacts/emails. V-work for now DONE; next: panel-other-services.md.
