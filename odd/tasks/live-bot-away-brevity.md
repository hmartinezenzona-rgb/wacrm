# Away notice and brevity on the live (Oct-19 based) Cerebro

## Objective

Bring the away-mode note and the follow-up brevity behaviour to the production Cerebro without
breaking what was restored and fixed on 2026-10-27 (Oct-19 bot + multi-Zelle, shortfall note,
`repartir_envio`, g82 split note).

## Problem and why

- On 2026-10-27 the owner restored production to the Oct-19 bot because the Oct 26-27 bot made
  more mistakes. Since then targeted fixes were added on top of it. The live Decisor is md5
  `747db79b` (Oct-19 `c2ed1d13` + the g82 Zelle/`repartir_envio` line).
- The repo Decisor (`pruebas/decisor/decisor.jscode`, HEAD `86bca125`, uncommitted `243f6cfd`)
  is a different lineage. Publishing it would undo the restore. It must not be published.
- The live Decisor has no away note and no brevity rules. The owner wants both, integrated into
  the current production code.

## Scope

- Vendor the live Decisor as its own source file with its own tests and md5 pin.
- Port onto it, as small changes:
  1. Away note: `AUSENCIA TEMPORAL` on the first contact of the day, `AUSENCIA YA AVISADA HOY`
     afterwards; only while the business is open (not out of hours, closed day or Sunday);
     malformed `cierre_especial.ausencia` ignored. Production already has migrations 264/270 and
     `Contexto conversacion` already returns `cierre_especial`.
  2. Follow-up brevity note (`TURNO DE SEGUIMIENTO (BREVEDAD)`), not fired when the customer asks
     for a new quote. Production `Contexto conversacion` has no `mensajes_cliente`, so the gate
     must use signals the live context already provides (route A, Decisor only; owner 2026-10-28).
  3. Do not repeat card and phone already confirmed (`soloAcuse`, `veniaDeAntes`).
- Out of scope unless the owner asks: "5 mil pesos" as GYD, "lista para transferir" wording,
  any query or node other than `Decisor`.

## Constraints

- Never execute the staging or production workflow.
- Backup before every write; owner go-ahead before every production write.
- Do not modify `pruebas/decisor/decisor.jscode`, `correr.ts`, `decisor-notas.test.ts` or
  `odd/tasks/bot-brevedad.md`: they carry another session's uncommitted work (staging `243f6cfd`).
- Commit only this feature's paths.

## TDD

- Mode: strict, on (source: global CLAUDE.md "Strict TDD Mode: enabled").
- Runner: `npx vitest run pruebas/decisor/produccion`.

## Tasks

- [x] T1 Vendor live Decisor `747db79b` to `pruebas/decisor/produccion/decisor.jscode` with a
  runner and an md5 pin test. Baseline characterization (g82 Zelle split note, Zelle notes,
  card/phone notes): 7/7 green on the unmodified file.
- [x] T2 Away note. RED 2 failing (open + first contact, open + already presented); GREEN. Gated on
  the live `abierto` (not Sunday, within hours, no `ce.hoy_motivo`); texts byte-identical to HEAD.
- [x] T3 Follow-up brevity note. Gate: `$('Ultima cotizacion').first().json.ultima_cotizacion`
  (last agent message within 6 h carrying a bold quoted amount) and not `pideCotizacion`.
  `Historial contacto.primer_del_dia === false` rejected: it is also true after a bare greeting.
  RED 1 failing; GREEN.
- [x] T4 No repeated card/phone confirmation. RED 2 failing; GREEN. Parent review found that
  `veniaDeAntes` alone also skipped the FIRST confirmation when the card came earlier and the
  phone arrives now; the skip now requires `!s.tarjeta && !s.celular`. RED 1 failing
  (`si la tarjeta vino antes y el celular llega ahora, confirma completo`); GREEN.
  Final: `npx vitest run pruebas/decisor` 2 files / 116 passed; repo Decisor md5 `7909d4f8`;
  diff vs live: 1 file, about 33 lines added, 1 changed; prettier clean on the new `.ts` files;
  `tsc --noEmit` clean (writer run).
- [x] T5 Publish: backup, owner go-ahead, `publicar-decisor produccion` with
  `CEREBRO_DECISOR_FILE`, verify md5 and versionId == activeVersionId.
  2026-10-28 owner go-ahead ("si"). Fresh `estado`: 86edf437, Decisor 747db79b, 128 nodes.
  Backup `produccion-jEzlVLCLUaJhVwzs-86edf437-...-20261028-055728.json`; `publicar-decisor
  produccion --esperado 747db79b` OK; versionId 8faa133b == activeVersionId, active, 128 nodes,
  Decisor md5 7909d4f8 == repo. Post backup `...-8faa133b-...-20261028-055752.json`: same node
  names, only `Decisor` changed, connections equal. `comparar` skipped: staging is another lineage.
  Workflow not executed (rule). Implementation commit e8f436f.
  Rollback: `restaurar produccion <055728 backup> --esperado 8faa133b`.
- [ ] T6 Owner check in production: activate an absence from the panel and check the first and a
  later reply; watch follow-up replies after a quote.

## Acceptance criteria

- Every existing live behaviour checked by the baseline tests is unchanged (g82 split note,
  Zelle notes, deposit notes).
- New tests prove the three behaviours; full `pruebas/decisor` suite still green.
- Production Decisor md5 equals the repo file; node count and other nodes unchanged.

## Progress

- 2026-10-28 created. RDD off (default). Live backup:
  `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/produccion-jEzlVLCLUaJhVwzs-86edf437-2f12-4750-afbf-bb57ed693d6e-20261028-054240.json`.

## Next step

T6. (T5 note) Staging was skipped on purpose: staging runs the repo lineage (132 nodes, Decisor `243f6cfd`),
so publishing this file there would not test anything and would overwrite another session's
staging work. The safety net is the offline suite, the backup and `restaurar`.
