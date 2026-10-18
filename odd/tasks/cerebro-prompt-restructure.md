# Cerebro: restructure the prompt from what the business actually does today

## Objective
Audit what the system really supports today, then restructure the agent prompt around that reality
instead of patching rules one at a time. Measured against the gold battery, which must be audited
too: part of it encodes the old reality.

## Why (owner, 2026-10-18)
The owner's diagnosis, after three of my rule-level fixes failed to change any behaviour: the prompt
is OBSOLETE. Many of its rules only held while the business was being tested, when a remittance
always arrived as CUP on a Cuban card. Production brought more ways to receive: USD in cash, USD on
a Clasica or Tropical card, Zelle, saldo movil, recargas, and more. So the prompt should not be
patched rule by rule — it should be re-derived from today's reality.

This supersedes the rule-by-rule approach recorded in `odd/tasks/cerebro-tool-consolidation.md`
(three prompt candidates, zero behaviour change). It does NOT supersede T2/T3 of
`odd/tasks/cerebro-context-prompt.md`, which are about token cost and organisation; this document is
about CORRECTNESS of content. They should land together.

## Audit: what the system supports today
Sources are named per row. Rates and the catalogue were read read-only from STAGING on 2026-10-18;
staging is at migration 242 and production at 239, so rows touching 240-242 are flagged. The code
lists come from the repo's migrations, which are the authority on what is accepted.

### Rates that exist at all
Only TWO rows exist in the `tasas` view: `gyd` = 3 (CUP per GYD) and `usd` = 260 (GYD per USD).
There is no separate rate row for Clasica, Tropical, saldo or recargas. Everything else is derived.

### Ways the beneficiary can RECEIVE a remittance
| rail | currency | how it is priced | source |
|---|---|---|---|
| `cuban_card` (alias `cup`) | CUP | `tasas` row `gyd`, 3 CUP per GYD | `tasas`, staging |
| `zelle` | USD | TIERED by the USD amount: `cerebro_tasa_zelle` / `cerebro_zelle_cotizar_gyd` | migration 231, prompt line 112 |
| `clasica` | USD | single `usd` rate, 260 | `tasas`, prompt line 181 |
| `tropical` | USD | single `usd` rate, 260 | same |
| `efectivo_usd` | USD cash in Cuba | ITS OWN rate and conditions, only through `consultar_servicio('efectivo_usd')` | `cerebro_servicios`, prompt line 179 |

### Other services, which are NOT remittance rails
| service | what it is | priced | human? | source |
|---|---|---|---|---|
| `recargas` | phone top-ups | `precio_recarga`: 500 CUP = 5,200 GYD, 600 CUP = 6,200 GYD | yes | `precio_recarga` table |
| `saldo` (saldo movil) | balance packages | packages of 360 CUP, cost 1.6 or 2 USDT depending on provider | — | migration 242 header |
| `combos` | food parcels | per recipient, amount in GYD | no | `cerebro_servicios` |
| `visa` | visa extension | 5,000 GYD per person, all up front by MMG | no | prompt line 131 |
| `traduccion` | document translation | from the service text | no | `cerebro_servicios` |
| `mexico` | payout in MXN | quoted in USD at 260 GYD/USD; a human converts at the day's rate; NO stored USD->MXN rate | yes | handoff 2026-10-17 item 6 |

`cerebro_servicios` holds exactly six, all active: combos, efectivo_usd, mexico, recargas,
traduccion, visa. `requiere_humano` is true for efectivo_usd, mexico and recargas.

### Two inconsistencies in the SYSTEM, not the prompt — owner decisions
1. **`mexico` is an active service but cannot be set as the operation's service.**
   `cerebro_cambiar_servicio` accepts nine values — cuban_card, zelle, clasica, tropical,
   efectivo_usd, recarga, combo, visa, saldo (plus aliases `cup` and `efectivo`) — and `mexico` is
   NOT among them, while the prompt does use `via=mexico` for quoting. So Mexico can be quoted and
   described but the operation cannot be moved onto it by the bot.
2. **`saldo` is the mirror image**: accepted by `cerebro_cambiar_servicio` but absent from
   `cerebro_servicios`, so `consultar_servicio` cannot describe it and the prompt never mentions it.
   The owner named saldo movil explicitly as something customers receive today.

Both predate this work and neither is caused by it. They need the owner's answer before the prompt
can describe them honestly.

## What the prompt says that is no longer true
All line numbers are the live production prompt of 2026-10-18 (51,154 chars, 373 lines).
- **line 105 — flatly false.** "El cliente siempre deposita GYD y en Cuba siempre se reciben CUP."
  Four of the five rails above are USD. This is the categorical premise the model follows, and it
  sits two lines above the routing rules.
- **line 116 — the template teaches the CUP default.** `COMO DECIRLO` hands the model the
  filled-in sentence "Por *30,000 GYD* llegan *60,000 CUP* a Cuba." MEASURED: the bot reproduces
  that exact sentence with the number swapped, on the very amount the examples use, and it kept
  doing so after lines 105, 108 and rule 4 were all fixed. A worked example beats a rule.
- **line 108 vs line 113 — a direct contradiction.** 108 says quote BOTH currencies and cites 113
  as its reference; 113 says quote NEITHER and ask. 108 is pre-change behaviour never removed.
- **rule 4 (line 227) — "moneda" means two different things.** "Numero suelto = GYD a enviar. No
  preguntes moneda" was about the currency DEPOSITED; read today it forbids asking the DESTINATION
  currency, which 113 requires. Line 114 was patched for the "30mil gy" spelling, which is exactly
  why one gold case behaves correctly and the bare-number ones do not.
- **the VIA USD section presents USD as the exception.** It opens "Hay clientes que no quieren CUP"
  and "Hay CUATRO y hay que PREGUNTAR". Structurally USD is a special case bolted onto a CUP
  default, when today CUP is one rail among five.
- **saldo movil appears nowhere** in the prompt, though the owner lists it as a live service.

### Structural diagnosis
The prompt is organised around "a remittance is CUP on a Cuban card", with everything else added as
exceptions. Every obsolete item above is a symptom of that single shape. That is why rule-level
edits did nothing: the default is asserted in the premise (105), demonstrated in the template (116)
and reinforced by the examples, so removing one conditional rule leaves the default intact.

The restructure therefore has to change the SHAPE: destination rail chosen first and never assumed,
with CUP as one option, and the pricing rule attached to each rail.

## The battery is part of the audit
Already proven on three cases: `reg-27065`, `reg-28021` and `reg-30178` expected a CUP figure the
current rules forbid, and two of them demanded `calcular_envio` as obligatory (corrected 2026-10-18,
previous expectation kept in `esperado_pre_regla_113`). Any case frozen before the USD rails existed
may encode the old reality the same way. The battery must be swept for this before it can judge a
restructured prompt — otherwise it rewards the old shape, which is what it did to me.

## Scope and constraints
- Read-only so far. Nothing in the prompt, the workflow or production has been changed by this
  document.
- Production only with the owner's explicit go-ahead, as always; staging first.
- The owner closed the memory/context token work on 2026-09-26 ("does not want to sacrifice
  context"). Token savings here come from the SYSTEM PROMPT only.
- Two owner decisions block honest copy for Mexico and saldo (see above).

## Tasks
- [x] T1 Audit what the system supports today (this document)
- [ ] T2 (owner confirmation) Agree the target SHAPE: rail chosen first, CUP as one option among
      five, pricing attached per rail
- [ ] T3 Sweep the gold battery for other expectations frozen before the USD rails, the way the
      three above were found
- [ ] T4 Restructured prompt candidate, measured against the swept battery with a variance run
- [ ] T5 Staging, then production with the owner's go-ahead

## Progress
- 2026-10-18: audit done. Rates confirmed as only gyd=3 and usd=260; six active services; five
  receive rails; the `mexico`/`saldo` mismatches found; six obsolete prompt items identified with
  line numbers, one of them measured as the actual driver (line 116).
