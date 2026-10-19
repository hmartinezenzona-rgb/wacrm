# Decisor: stop ordering a CUP quote when nobody said the rail

## Objective
The `Decisor` code node injects an instruction into the model's context that assumes the
beneficiary receives CUP and dictates the exact sentence to say — precisely when no rail is known.
Remove the guess, keep the part that is actually knowable, and prove it with a test that runs the
real node code offline.

## Why (measured in T4 of `odd/tasks/cerebro-prompt-restructure.md`, 2026-10-18)
The restructured prompt reached 45/60 against 43/60, with zero regressions, but two reds would not
move: `reg-27065` and `reg-28021`. Both fail identically (`llamó la PROHIBIDA calcular_envio`) and
both answer, word for word:

> Por *30,000 GYD* llegan *90,000 CUP* a Cuba.

That is not the model improvising and it is not prompt line 116. It is dictated by this node. So the
CUP default was asserted in the prompt premise (105), demonstrated in its template (116) **and
ordered by code**, which is why three rule-level prompt fixes moved nothing: the prompt was never
the last word.

## The defect, exactly
Production workflow `jEzlVLCLUaJhVwzs`, node `Decisor`, 1078 lines, md5
`c2ed1d13c177dc368fbfd63150e706e7`. Staging `U52y1kSNvhgxvWeb` carries the SAME md5, so there is no
drift to reconcile.

Lines 499-512 ("DIRECCION DEL CALCULO") run when the message has a quotable amount and
`g83Destinos` is empty — that is, when the client did NOT attach a destination currency to the
amount, so the rail is UNKNOWN. Both branches then assume CUP:

- `pideDeposito && !pideLlegada` -> "es el monto de DESTINO **en CUP**. Usa calcular_inverso... di
  'Para que lleguen *X CUP* necesita depositar *Y GYD*.'"
- `pideLlegada` -> "es lo que EL DEPOSITA, en GYD... Usa calcular_envio... di
  'Por *X GYD* llegan *Y CUP* a Cuba.'"

Both are prefixed "ya resuelto por el sistema, no lo replantees", which tells the model not to
reconsider. The guiding comment above them, line 498, is the obsolete premise itself:

> `// Origen SIEMPRE es GYD (o MXN/USD); destino SIEMPRE CUP. Nadie envia CUP.`

That is the same sentence as prompt line 105, which the T1 audit already found false: four of the
five receive rails are USD.

This block is NOT gate 83. Gate 83 (`g83Destinos`, lines 453-495, owned by
`odd/tasks/destination-amount-and-partial-card.md`) handles the case where the client DID attach the
currency, so there the rail is known and naming a calculator is correct. The defect is the
contiguous block below it, the one that runs when nothing was attached.

### What is RIGHT in that block and must be kept
Deciding which SIDE the amount is on from the phrasing ("cuanto llega" -> it is the deposit; "para
que lleguen" -> it is the destination) is correct, useful, and the same thing the restructured
prompt's PASO 2 does. The bug is not the side; it is asserting the destination CURRENCY, naming a
calculator, and dictating the sentence before the rail is known.

### The node already contradicts itself, and already knows better
Line 916 can fire in the SAME turn, from the same node:

> `TODAVIA NO SE SABE POR QUE VIA RECIBE: ... todavia no sabes si va a recibir en Cuba o por Zelle.`

So one note says the rail is unknown while another orders a CUP calculation and the CUP sentence.
Lines 930-934 of this very node record the project's own lesson about this exact failure mode, from
2026-08-10:

> `Dos ordenes opuestas en el mismo contexto: el modelo se quedo con la que prometia. El fallo era
> del contexto, no del modelo.`

This block is a second instance of that, unnoticed until now.

Also relevant: `rielOp` (`ctx.riel_operacion`) and `viaSinDefinir` already exist in the node — at
lines 910-911, four hundred lines AFTER the note that needs them. The signal the fix requires is
already computed, just too late.

## The battery CANNOT measure this change
`evaluar.py:montar_workflow` builds a temp workflow with only the webhook, `Contexto conversacion`,
`Entrada`, the agent, the model and the tools. **There is no `Decisor`.** Each gold case carries its
`[CONTEXTO]` baked into `entrada.mensaje`, recorded in August. So the battery replays the OLD note
verbatim no matter what this node does, and a green there would prove nothing about the fix.

Verification therefore has two parts:
1. an offline harness that runs the REAL node code under node.js with the 7 `$('...')` nodes stubbed
   (the node uses no `$input` and no luxon, only `$('Name').first().json` and
   `$('Datos del negocio').params.jsonOutput`), asserting the notes it emits;
2. after the node change ships to staging, regenerating the baked `[CONTEXTO]` of the affected gold
   cases from the NEW node output — mechanically derived from system output, not re-arbitrated — and
   re-measuring the prompt candidate.

## Scope and constraints
- Staging first, production only with the owner's explicit go-ahead, as always.
- The node is 92,614 chars of live production logic with 126 sibling nodes. The change touches
  lines 498-512 and hoists one `const`. Nothing else.
- Keep the side-of-the-amount logic. Keep `g83Destinos` untouched.
- Make the new note rail-AWARE: with `rielOp` set, the destination is known and the note should name
  that rail's calculator; only without it does the note forbid guessing and require asking.
- The vendored copy in the repo carries the md5 above so drift from n8n is detectable.

## Tasks
- [x] T1 Vendor the live node code into the repo and build the offline harness that runs it with
      stubbed n8n globals — `pruebas/decisor/decisor.js` + `correr.ts`; `vitest.config.ts` now also
      includes `pruebas/**/*.test.ts` (commit 87da530)
- [x] T2 RED: 6 of 11 failing, and the 5 passing were exactly what had to survive (commit 87da530)
- [x] T3 GREEN: 11/11, with a differential proving only the quoting note changed
- [ ] T4 Apply to staging `U52y1kSNvhgxvWeb`, verify the live node matches the candidate, owner
      checks a real conversation
- [ ] T5 Regenerate the baked `[CONTEXTO]` of the affected gold cases from the new node, then
      re-measure the prompt candidate of `cerebro-prompt-restructure.md` T4
- [ ] T6 Production `jEzlVLCLUaJhVwzs` with the owner's go-ahead, with a rollback copy first

## Progress
- 2026-10-18: defect located and scoped read-only. Nothing changed in staging or production.

### T3 done — what the note says now, and the proof it changed nothing else
The block keeps deciding the SIDE and stops deciding the currency. With no rail:

> `LADO DEL MONTO (lo resolvio el sistema, no lo replantees): el cliente pregunta CUANTO LLEGA, o
> sea el monto que dijo es lo que EL DEPOSITA, en GYD... La VIA NO SE SABE: nadie ha dicho por donde
> recibe quien recibe, y hay varias. PROHIBIDO asumir una y PROHIBIDO dar una cifra todavia.
> Pregunta primero en que moneda quiere que le llegue y, cuando lo diga, cotiza con la herramienta
> de ESA via.`

With a rail already chosen it names that rail's calculator in the right direction, from a `VIAS`
table covering the six remittance rails (`cuban_card`, `zelle`, `clasica`, `tropical`,
`efectivo_usd`, `mexico`). `rielOp` was hoisted from line 910 to the top of the block; the later
declaration became a comment so `viaSinDefinir` keeps working.

Verification, beyond the 11 green tests: a differential ran the node BEFORE and AFTER over 15 turns
and diffed every note. **6 turns differ and in all 6 the only difference is the quoting note; 9 are
byte-identical**, including both gate-83 shapes, recarga, combo, greeting, pure acknowledgement,
card+phone, the rate question and a bare amount. Full suite 2797/2797, typecheck and lint clean.

One deliberate behaviour change found by that differential: with a **recarga** in progress the node
used to order a CUP quote (`calcular_envio` + the dictated sentence) and now emits no quoting note
at all. That is a fix, not a loss — a top-up is priced from `precio_recarga`, never from the CUP
rate, so the old note was wrong there too. The `OPERACION EN CURSO: RECARGA DE SALDO` note owns
that amount. Same for combo, visa and saldo.
