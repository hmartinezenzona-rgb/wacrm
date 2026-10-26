# Bot brevity: one away notice, no recaps, specific asks

Status: IN PROGRESS (2026-10-26). The Decisor fixes and a third prompt candidate are ready; the
117-case gold battery is running. Nothing is deployed yet.

## Why

Measured on 502 turns / 69 conversations (19–25 Oct): median 19 words per turn, bot/customer ratio
~3, repeated greeting 17.9 % of turns (11 same day), the away notice repeated every turn, full
quote recaps on a simple "¿me entendió?", and a generic "pásame los datos de quien recibe" when one
concrete datum was missing.

## Decisor fixes (root)

- **Away notice once:** the full `AUSENCIA TEMPORAL` note is only emitted when
  `Historial contacto.primer_del_dia` is true. On later turns the note becomes
  `AUSENCIA YA AVISADA HOY`: do not repeat the reason or the return time; if asked whether it can
  happen today, say exactly "Hoy no se lo puedo prometer" or "no depende de mí"; if the deposit is
  verified, say so.
- **Follow-up brevity:** when `mensajes_cliente > 1`, the Decisor forbids re-listing the quote,
  rates, minimums or table; the answer is 1–2 sentences (max 40 words), asks only for the missing
  datum (the card, the phone), never "los datos de quien recibe", and avoids "Total a depositar".

## Prompt candidate v3

`~/cerebro-fase1/pruebas/evals/candidato-prompt-estilo-2026-10-26b.txt` (59,235 chars), based on the
measured 2026-10-26 candidate (58,884 chars) plus:

- the specific-ask example (tarjeta y celular, not the generic package);
- the exact away phrases for "¿hay posibilidad hoy?";
- the 40-word follow-up rule.

The original measured candidate and its A/B reports are kept unchanged.

## Evidence

- Decisor tests: 86/86; md5 `9880cb3789ce37e5d736709d2aca66e9`; the new tests cover the away repeat,
  the first-contact full note and the follow-up brevity note.
- Style A/B iteration 2 (2026-10-26 08:40, 10 reps): the candidate improved the baseline but the
  cases remained unstable (recap 5/10, generic tail 6/10, away repeat 7/10; one away case 10/10).
  The Decisor fixes target exactly those three failures; the style cases use fixed contexts, so a
  new A/B needs a context snapshot to see the Decisor effect.
- Gold battery: running on `casos-conversaciones.json` (117 cases) with the v3 prompt.

## Tasks

- [x] T1. Decisor away-once + follow-up brevity notes and tests.
- [x] T2. Prompt candidate v3 with the specific asks and exact phrases.
- [ ] T3. Gold battery green (117 cases).
- [ ] T4. Deploy the prompt and the Decisor to staging, then production with the owner's go-ahead.
- [ ] T5. Measure production (repetition/recap rate) and compare with the 502-turn baseline.

## Rules

- No prompt deployment without the gold battery green (skill `wacrm-cerebro-n8n`).
- The prompt deploy uses `desplegar_prompt.py --candidato <file> --etiqueta <tag>` and writes a
  ROLLBACK first.
- The Decisor deploy uses `publicar-decisor` with a fresh `estado` md5 per environment; production
  needs the owner's go-ahead.
