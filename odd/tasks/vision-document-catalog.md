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
- [ ] V0 Catalog: collect customer images with the vision verdict and the outcome; select the misreads (receipts
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
