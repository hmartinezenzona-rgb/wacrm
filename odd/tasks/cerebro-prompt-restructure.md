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

### Owner's decision on scope (2026-10-18)
The bot must be able to SELL and SET every service, including saldo movil and Mexico: quote, answer
questions, collect the data, and fix the operation's service. What it must NOT do is move money —
and that is already correct today, because the system has no transfer tool at all; the admin does
every transfer. So the boundary is not "bot vs human per service", it is "everything up to the
transfer is the bot's, the transfer is the admin's".

This makes the two mismatches below PREREQUISITES of the restructure, not side notes: the prompt
cannot be told to set Mexico while the function rejects it, nor to describe saldo while nothing can
describe it.

### CORRECTION to this audit: saldo movil is fully modelled, just invisible to the bot
My first pass said saldo was barely modelled. Wrong. Migration **223 `saldo_movil_service`** models
it completely, as its own operation service:
- `remittance_operations_service_chk` accepts `saldo`; the recipient is the phone-only row type,
  exactly ONE Cuban number per saldo operation.
- Price and size are DATA in `cerebro_config`, verified live on staging 2026-10-18:
  **`precio_saldo_gyd` = 1000 and `saldo_unidad_cup` = 360**, i.e. 1,000 GYD buys a package of 360
  CUP of saldo. Sold all year, not promo-bound.
- `calculator_rate_versions.saldo_costo_usdt` carries its USDT cost (1.6 or 2 per package depending
  on the provider, per migration 242).

So the sale price never needed asking — it is data. And the 223 header already anticipated this
exact gap: the config values are "read by the app card and **the later bot**". The bot half was
never built. What is missing is ONLY the `cerebro_servicios` row and the prompt copy.

(Also verified live: `zelle_minimo_gyd` = 13000.)

### Two inconsistencies in the SYSTEM, not the prompt — now prerequisites
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
- [x] T2 Scope settled by the owner: the bot sells and sets everything; only the transfer is the
      admin's, which the system already enforces by having no transfer tool
- [x] T2a PREREQUISITE — `saldo` gains a `cerebro_servicios` row so `consultar_servicio('saldo')`
      can describe it. Content derived from data, not invented: 1,000 GYD per package of 360 CUP,
      one Cuban phone per operation. Migration 223 anticipated this ("the later bot")
- [ ] T2b PREREQUISITE — `cerebro_cambiar_servicio` accepts `mexico`, so the bot can set it as it
      can already set the other eight. Touches a function with rail locks and audit rows, so it
      needs its own RED/GREEN assertion and a rollback, like 230/231 did
- [x] T2c Target SHAPE agreed before writing copy: rail chosen first and never assumed, CUP as one
      option among five, the pricing rule attached to each rail, and the services the bot can now
      sell listed as first-class rather than as exceptions
- [x] T3 Sweep the gold battery for other expectations frozen before the USD rails, the way the
      three above were found
- [x] T4 Restructured prompt candidate, measured against the swept battery with a variance run.
      `odd/artifacts/cerebro-prompt-candidato-vias.txt`. 45/60 vs 43/60 base, zero regressions;
      `reg-27486` 7/8 green vs 1/6 on the live prompt. Found and fixed my own `=` defect that
      disabled every n8n expression. Found the real CUP driver in the `Decisor` node (T6)
- [ ] T5 Staging, then production with the owner's go-ahead. BLOCKED on migration 244 reaching
      production first, because the candidate routes `'saldo'` to `consultar_servicio('saldo')`
- [ ] T6 `Decisor` node stops asserting CUP and stops dictating the quote sentence when no rail is
      known. This is the measured driver of the two remaining systematic reds; the prompt cannot
      reach it. n8n production change: owner's go-ahead, staging first, own feature document
- [ ] T8 Last home of the CUP default: the `Decisor` reparto note says "CUANTOS CUP recibe cada
      persona". NOT folded into the Decisor fix on purpose — it changes reparto behaviour, which has
      its own feature document and gold cases (`reg-30478`), and doing it in the same breath is the
      very habit that caused today's mess. Needs its own test
- [ ] T9 Regenerate BOTH frozen layers of the battery: the baked `[CONTEXTO]` (6 cases, with the
      `doble-pregunta` caveat in the Decisor doc) and the recorded tool results, starting with
      `consultar_tasas`. Then one full-battery run of prompt + Decisor together
- [ ] T7 `visa.resumen` says 4,000 GYD while its own `hechos` and the prompt say 5,000. Now that
      the prompt carries no price, the catalogue is the only authority, so the bot would quote the
      stale 4,000. Small migration + rollback, and `reg-25682`'s expectation revisited with it

## Progress / evidence

### T2a done on staging — saldo movil is visible to the bot (2026-10-18)
Migration `244_saldo_movil_catalog.sql` + `ROLLBACK-244-saldo-movil-catalog.sql`.

It does TWO things, and the second was the real bug: **`saldo` was in the KEYWORDS of `recargas`**
(migration 138 set `ARRAY['recarga','saldo','etecsa','cubacel']`), so every customer question about
saldo was routed to the Etecsa-promotion recharge service — a different product, a different price,
and one that does not exist outside a promotion. A catalogue row alone would have left that intact.

Price is composed at insert time FROM `cerebro_config`, not retyped, so the row cannot disagree with
the configured price on the day it ships.

| | before | after |
|---|---|---|
| `saldo` row | absent | present, `requiere_humano = false` (the bot sells and sets it) |
| `recargas` keywords | `{recarga,saldo,etecsa,cubacel}` | `{recarga,etecsa,cubacel}` |
| `saldo` keywords | — | `{saldo,"saldo movil","recargar saldo","poner saldo"}` |

Functional check: `cerebro_servicio_get('saldo')` returns the service with "1000 GYD por cada
paquete de 360 CUP de saldo", which is what the bot will read. Staging keeps 244; production
untouched.

Three things noticed while doing it, all pre-existing and none fixed here:
- `cerebro_servicio_get` returns `notas_internas` TO THE MODEL, so maintainer notes (file paths,
  migration numbers) land in its context as noise. Every existing row does this, `efectivo_usd`
  most heavily. Candidate for the restructure, not for a quiet change now.
- `efectivo_usd`'s rate lives as PROSE inside its `hechos`: "290 GYD por cada 1 USD ... minimo 100
  USD". So the cash rate is 290, not the 260 of Zelle/Clasica/Tropical, and it is NOT in `tasas` —
  changing it means editing service text by hand. That is why the prompt forbids the USD
  calculators for cash, and it is a second instance of the fragility 244 deliberately avoided.
- `visa`'s `resumen` says 4,000 GYD while its own `hechos` and the prompt say 5,000. Stale summary,
  recorded for the sweep, not touched.

### T2b is BLOCKED, and it is much bigger than "accept one more value" (2026-10-18)
Investigated before writing anything, and nothing was changed.

**Mexico does not exist as an operation on any axis.**
- `remittance_operations.service_type` accepts `remesa`, `recarga`, `combo`, `visa`, `saldo`. No
  `mexico`.
- `delivery_method` accepts `cuban_card`, `clasica`, `tropical`, plus the service rails `recarga`,
  `combo`, `visa`, `saldo` (and `efectivo_usd`). No `mexico`.
- `'mexico'` appears in migrations only as a `cerebro_servicios` catalogue key and inside an old
  pipeline list from migration 046 (`('remesa','combo','recarga','visa','traduccion','mexico')`),
  from the previous model. The current operations table cannot hold a Mexico operation.

So today Mexico is DESCRIBE-and-QUOTE only, and that part already works: the catalogue row answers
questions and the USD single rate (260) quotes it. What cannot happen is FILING the operation —
which is exactly what "the bot sets it" would require.

Adding `mexico` to `cerebro_cambiar_servicio` alone would therefore write a service the operations
table rejects, or worse, pass the CHECK on some other axis and produce a half-formed money
operation. That is why this stops here.

**Three decisions only the owner can make, because guessing would put wrong numbers on real money:**
1. **Which axis.** Is Mexico a `remesa` with a new `delivery_method = 'mexico'` (it is a remittance
   that happens to be delivered in Mexico, like cash in Cuba), or its own `service_type = 'mexico'`
   the way saldo and visa each got one? The first is cheaper and matches how it is sold.
2. **What goes in `destination_amount` / `destination_currency`.** There is NO stored USD->MXN rate:
   the business quotes in USD at 260 GYD/USD and a human converts at the day's rate. So does the
   operation store USD (what was actually quoted and agreed) with the MXN conversion left to the
   admin, or MXN with no amount until the admin fills it? `_cambiar_servicio_core` re-quotes on every
   change, so it needs a defined answer.
3. **What recipient data Mexico needs.** The prompt's routing keywords are `mexico`, `clabe`,
   `coppel`, `bbva`, so it is an account at a Mexican bank. There is no beneficiary row type for that
   today — the existing ones are Cuban card, phone, Zelle account and cash delivery. A new type means
   touching the beneficiary model, its parser and the panel.

**This does NOT block the restructure.** If Mexico stays "quote, answer, collect the data and hand
the filing to the admin", the restructured prompt can describe it honestly today, and T2b becomes a
separate feature with its own document. Only "the bot FILES a Mexico operation" needs T2b.

#### Owner's answer (2026-10-18): Mexico is one more DELIVERY RAIL
"es una via mas de entrega de dinero": the customer deposits GYD into the business account in
Guyana, and then the business pays the relative in MEXICAN PESOS in Mexico, through the channels
available there. Structurally identical to cash in Cuba: one deposit in GYD, a payout in the
destination currency, performed by a human.

That settles decisions 1 and 2:
1. **Axis: `delivery_method = 'mexico'` on a `remesa`.** NOT its own `service_type`. A Mexico
   remittance is a remesa whose payout happens in Mexico, exactly as `efectivo_usd` is a remesa
   whose payout happens in cash in Cuba.
2. **Amount: stored in USD.** Not a choice so much as the only honest option — the single `usd` rate
   (260 GYD/USD) is the only rate that exists, it is already what the prompt quotes for Mexico, and
   there is no stored USD->MXN rate. So the agreed figure is the USD one and the peso amount is set
   by the admin at payout, the same division of labour the business already uses. A stored MXN
   amount would be a number nobody computed.

Decision 3 is the only one left, and it is narrow. Today's beneficiary types are
`cuban_card`, `zelle`, `clasica`, `tropical`, `multiple_distribution`, `efectivo_usd`, `recarga`
and `combo`. None of them holds a Mexican bank account. Note the precedent: `saldo` has NO type of
its own, it reuses the phone-only `recarga` row (migration 223). And `zelle`'s shape — holder name
plus one account string — is structurally identical to name plus CLABE, so reuse is technically
possible, though it would show the wrong label to the operator who has to make the payout.
Recommendation: a new `mexico` beneficiary type, because the panel and the parser display it to
whoever pays.

What is still needed from the owner is only WHAT TO COLLECT: name plus CLABE, or name plus bank plus
account number, and whether the payout channel varies (the prompt's keywords are `clabe`, `coppel`,
`bbva`, which suggests it might). That answer defines the row and the questions the bot asks.

#### Decision 3 was already answered by the system — I should have looked before asking
The owner pushed back: those details might already be in the Cerebro, its tools or Engram. He was
right. Engram had nothing and `Datos del negocio` no longer even has a `mexico` key (the Albo
account was removed in the vision change of 2026-10-17), but the `mexico` row of
`cerebro_servicios` specifies the recipient model in full:

**Two ways to receive in Mexico**
1. **Bank account** — needs CLABE, bank and the account holder's name. THREE fields.
2. **Cardless withdrawal** — needs to know whether they have a **Coppel** or a **BBVA** nearby,
   the only two banks handled. It does NOT pay fractions and only accepts **multiples of 100**.

And three facts that were missing from the audit:
- rate 260 GYD/USD and a **minimum of 13,000 GYD (50 USD)** — the same floor as Zelle
  (`zelle_minimo_gyd` = 13000);
- no maximum, but large amounts must be flagged in advance;
- paid out the same day, usually minutes after the payment is verified.

So no owner decision is pending. The recipient model is richer than any existing beneficiary type:
`zelle`'s single account string cannot hold holder + bank + CLABE, and the cardless variant stores a
bank CHOICE rather than an account. Two sub-shapes under one `mexico` type.

**The multiples-of-100 rule is a QUOTING constraint, not just recipient data.** If the customer
picks cardless withdrawal, the USD figure has to be a multiple of 100. Neither the four calculators
nor the merged `cerebro_cotizar` of migration 243 knows that, so a cardless Mexico quote can produce
an amount that cannot be paid out. Recorded here as a defect to cover in T2b, found while reading
the catalogue rather than from any failure.

#### Scope of T2b, now that the shape is known
No longer "accept one more value". It is: `delivery_method` CHECK gains `mexico`; `rb_type_chk`
gains a Mexico recipient type; `cerebro_cambiar_servicio` accepts `mexico` and re-quotes it with the
single USD rate; the beneficiary parser and the panel learn the new type; plus the usual RED/GREEN
assertion, rollback and fingerprint, on a function that carries rail locks and audit rows. Its own
feature document, not a prerequisite tweak.

### T3 — battery sweep (2026-10-18)
**The whole battery is a snapshot of August 2026.** All 60 cases have `origen.fecha` in 2026-08, and
58 of them carry `arbitrado: humberto 2026-08-12` (2 are unarbitrated). Everything below shipped
AFTER that date: the cash service (137, 2026-09-28), saldo movil (223, 2026-10-06), the tiered Zelle
pricing (215/217, 2026-10-05), the service-change tool (230/231, 2026-10-08), the partial-data
beneficiary tools (179/180, 2026-10-01), and the `COTIZACION SIN MONEDA DE DESTINO` rule.

Exposure by what the expectation depends on:
| cases | area | families |
|---|---|---|
| 28 | quoting: rates, tiers, destination currency | calculo, calculo-con-herramienta, calculo-desde-contexto, multi-herramienta, saldo-envio |
| 10 | rail / beneficiary | beneficiario-zelle, reparto-multiple |
| 7 | services: prices and conditions | servicios, promo |
| 15 | style and behaviour, probably survives | comprobante, derivar-humano, formato, ingles, otros, saludo-despedida |

**45 of 60 touch something the new reality changed.** 3 are already corrected.

**But the FIGURES still hold today, and I nearly reported otherwise.** The recorded mocks quote Zelle
at a flat 260, and Zelle is now tiered, so two cases expecting 500 USD = 130,000 GYD and 510 USD =
132,600 GYD looked stale. Checked against the database: `cerebro_tasa_zelle` returns **260 for 50,
115, 500 and 510 USD alike**, so `gyd_hoy = gyd_a_260` in every one. The tiers exist structurally but
currently sit at the same price. No figure in the battery is wrong because of them.

So the precise conclusion is narrower and more useful than "45 cases are rotten":
- What is stale is not the NUMBERS but the BEHAVIOURAL expectations — which tool, whether to quote at
  all, which rail — exactly the shape of the three already found and corrected.
- The battery is structurally FRAGILE rather than currently wrong: its figures are frozen against
  rates that are now data (`tasas`, the Zelle tier table, `cerebro_config`). The day a tier price or
  the CUP rate changes, dozens of cases silently go red for a reason that has nothing to do with the
  bot.

**Re-arbitration of the 45 is the owner's call, not mine.** The field is literally
`arbitrado: humberto`. For the three already corrected I derived the answer mechanically from his own
written rule and his own worked examples, which is defensible; doing that across 45 cases would be
me rewriting the product spec. What I can do, and what T4 should start with, is hand him the exposed
cases grouped by the single decision each group needs, so he answers per group instead of per case.

### T2c — the target shape of the restructured prompt
Derived from the audit and from what was measured, not from taste.

1. **Open with the real premise, not a CUP one.** The customer always deposits GYD; what the
   beneficiary receives is CHOSEN and never assumed. This replaces line 105, which asserts the
   opposite as a fact.
2. **One rail table instead of three scattered sections.** Per rail: what it is, what prices it (or
   which tool returns the price), what data to collect, and its minimum. This absorbs today's
   `TOOLS DE CALCULO`, `VIA USD` and `OTROS SERVICIOS`, where the same rail is described in two or
   three places and sometimes contradicts itself.
3. **One quoting rule.** Never quote before the rail is known; the tool computes and the model never
   does arithmetic. Said once, not re-derived per phrasing, which is what produced the 108/113/rule-4
   tangle.
4. **Examples must demonstrate the new shape — this is the lever, and it is measured.** Line 116
   currently hands the model the filled-in CUP sentence for the very amount the examples use, and the
   bot reproduces it verbatim; three rule-level fixes did not move that. So: one worked example per
   rail, and the CUP template loses its privileged position. A worked example beats a rule, which is
   the project's own lesson written inside `calcular_usd`.
5. **Facts live in the catalogue, not in the prompt.** Prices and conditions come from
   `consultar_servicio`; the prompt says where to look and never carries the number. This is the
   structural fix for staleness: `efectivo_usd`'s 290 rate and the Mexico minimum are prose inside
   service text today, and 244 deliberately avoided repeating that mistake for saldo.
6. **Keep what works, untouched.** The SKIP rules, the style rules, the registration golden rule
   (which gate 78 measured from 0 to 100% on the real cases), the security rule and the handoff rule.
   None of them is implicated in any finding here.

Not yet written. T4 writes the candidate and measures it, which cannot begin honestly until the
owner's group answers from T3 exist — otherwise the swept battery still rewards the August shape.

### The governing principle, from the owner (2026-10-18) — and my framing was wrong
The owner, asked to arbitrate three "decisions", answered with a principle instead and said plainly
that he did not understand the decisions as I had posed them. That is a fair criticism: I framed
them as test archaeology ("what August expected versus what rule 113 says"), which forces him to
hold the project's history in his head. He thinks in terms of the business.

His principle, in his words: to quote you have to know what the customer wants; if you do not know,
you cannot quote, and if you do not know you can ASK, and then you would know — which is what a
human would do, and what he would do. **The bot must not guess. If it is asked something it knows,
it answers; if it does not know, it invents nothing.**

Reframed that way, all three "decisions" dissolve:
1. **Quoting without a stated rail — answered by the principle.** Do not guess the destination
   currency; ask. The 2 remaining cases get the same correction as the 3 already done, and those 3
   are confirmed rather than at risk of reversal.
2. **Partial registration — the owner had ALREADY decided this**, on 2026-10-01: "las herramientas
   deben ser capaces de registrar datos a medias y en el orden que lleguen"
   (`odd/tasks/partial-beneficiary-tools.md`). A human writes down what arrives so it is not lost.
   The 12 cases are frozen before his own instruction. Nothing to ask.
3. **Service prices — never a decision, an internal inconsistency.** `visa`'s `resumen` says 4,000
   GYD while its own `hechos` and the prompt say 5,000. `hechos` is the authoritative
   customer-facing text, so the summary is simply stale and should be made to agree with it.

So ZERO owner decisions remain. I had been asking him to re-decide things he had already decided,
dressed up as test archaeology.

#### This replaces point 1 of the target shape
T2c opened with "the customer always deposits GYD; what the beneficiary receives is chosen, never
assumed". The principle is better, because it is not an enumeration: it covers every rail and every
service, including ones added later, and it covers questions as well as quotes. The restructured
prompt should open with it:

> No adivines. Para cotizar hay que saber que quiere el cliente: si no lo sabes, preguntas. Si te
> preguntan algo que sabes, lo respondes; si no lo sabes, no inventas nada.

Everything measured in this document is an instance of that principle being violated by the prompt's
own structure: line 105 asserts a destination instead of asking, line 116 demonstrates a guess, and
the 108/113/rule-4 tangle argues about when guessing is allowed. One principle replaces the
argument.

### T4 — two more contradictions, found by reading the stable red instead of the rules
The candidate lives at `odd/artifacts/cerebro-prompt-candidato-vias.txt` (versioned on purpose: the
five August candidates live outside git in `~/cerebro-fase1/pruebas/evals/`, which is part of why
this work is hard to audit).

Before writing it, `reg-27486` was read as evidence rather than as a score. Its message is
**"Amigo deposite en su cuenta para 50 zelle"**, and it fires TWO prompt rules in opposite
directions on one sentence:
- line 106: a monto with the rail attached ('120 Zelle') is what the beneficiary RECEIVES ->
  `calcular_usd`;
- line 107: a phrase with 'depositar' + monto is what the client DEPOSITS -> `calcular_envio`.

The bot resolves the contradiction by asking instead of quoting: observed reply "¿Depositó 50 GYD o
quiere enviar 50 dólares por Zelle?". That is why `reg-26685` ("Para comprale 120 Zelle") is green
and this one is red — not the amount, the VERB. Rules keyed on phrasing cannot be made consistent by
adding more phrasings, which is the same shape as the three failed rule-level fixes.

A second one, same class: **rule 3 (line 226) vs line 106**. Rule 3 says 'pesos'/'CUP' does NOT
imply `calcular_inverso` and that only 'que lleguen'/'que reciba' does; line 106 says '15 mil CUP'
DOES go to `calcular_inverso`. Two rules, opposite answers, both live.

So the single quoting rule needed a third part nobody had written down: **which SIDE the amount is
on**. The candidate states it once, with explicit precedence — a rail or destination currency glued
to the amount makes it the destination amount, and the verb never overrides that. Rules 3 and 4 now
point at that rule instead of restating it.

What the candidate does, against T2c: the principle opens it verbatim; `TOOLS DE CALCULO`, `VIA USD`
and `OTROS SERVICIOS` collapse into one `LAS VIAS` table (six rails, CUP as row one of six, not the
default) plus one `COMO COTIZAR` of four steps; the `COMO DECIRLO` template of line 116 is GONE as a
pre-filled sentence and the examples carry one worked quote per rail, with CUP no longer first;
every price left the prose (including visa's "5,000 GYD por persona", now read from
`consultar_servicio('visa')`). Kept untouched: SKIP, ENTRADA, the style rules, the registration
golden rule, rule 10, rule 13.

Structural check before measuring: all 7 distinct n8n expressions survive, none invented, none lost
(one `negocio.nombre` dropped from an internal `##` note, not from customer-facing text).
**The candidate GROWS the prompt 4.5%** (51,154 -> 53,457 chars). Consolidation saved less than the
principle, the rail table, Mexico/saldo and five new examples cost. Recorded rather than paid for by
deleting examples to hit a number nobody set as a criterion.

Two dependencies the candidate creates, both for T5 and neither for T4:
1. It routes `'saldo'` to `consultar_servicio('saldo')`, which exists only from migration 244.
   Production is at 239, so **the prompt cannot ship to production before 244 does**. No gold case
   touches saldo movil (the `saldo-envio` family is about a remaining balance), so the measurement
   is unaffected.
2. `visa`'s stale `resumen` (4,000 GYD vs 5,000 in its own `hechos` and in today's prompt) now
   matters more, not less: with the number out of the prompt the catalogue is the only authority, so
   the bot would quote 4,000 for a 5,000 service. Its own small task, deliberately NOT folded in
   here — mixing a catalogue fix into the prompt measurement would blur which change moved what,
   which is the lesson this whole feature has been paying for.

#### The leading `=` is load-bearing, and removing it broke every expression
My first candidate dropped the stray `=` that opens the live prompt (`=## ROL`), judging it cosmetic
noise. It is not: in n8n a parameter whose string value starts with `=` IS AN EXPRESSION, and
without it the value is a literal. Removing one character disabled interpolation for all 7
expressions at once, so the bot answered a customer with the raw template:

    *Account holder:* {{ JSON.parse($('Datos del negocio').params.jsonOutput).agente.titular }}

Caught by exactly ONE gold case, `reg-26602-ingles`, which is the only one whose expectation pins a
literal interpolated value (`6762167`, the MMG account). The subset of 14 I measured first would
never have caught it: the leak is invisible to every case that does not assert an account number,
and it scored 44/60 while broken. That is the argument for running the whole battery even when the
subset looks clean, and it is also a gap in the battery worth naming — one case stands between this
class of defect and production.

The structural check I ran before measuring (all expressions present, none invented, none lost) was
necessary and not sufficient: it compared the SET of expressions, not whether n8n would evaluate
them. A character outside any expression decided that.

Also found while picking the measurement set: **`reg-26966` and `reg-27123`, the last two cases of
T3's decision 1, are SALTADO** — both carry `historial_requerido` with no historial, so they have
never run. Correcting them to the principle is bookkeeping with no measurable effect, which is worth
knowing before claiming the sweep changed a score.

#### T4 measurement of record (2026-10-18)
Baseline and candidate were both run TODAY against the corrected battery, so the comparison is not
against yesterday's reports. Full battery, 60 cases, 12 SALTADO in every run.

| run | result | report |
|---|---|---|
| base, live prompt | **43/60**, 5 reds | `informe-20261018-181331.json` |
| candidate, `=` missing (invalid) | 44/60 | `informe-20261018-183120.json` |
| candidate, corrected | **45/60**, 3 reds | `informe-20261018-184926.json` |

**Zero regressions**: no case green on the baseline went red on the corrected candidate. Raw-template
leaks in the corrected run: 0 of 60.

The honest reading of +2 is weaker than the number looks. `reg-32598` is known flaky (green in the
stage-A baseline and both stage-A candidate reps, red in the full baseline, green in the full
candidate), so it is noise, not a gain. `reg-25682-servicios` is a plausible causal gain: it is the
visa case, and removing visa's price from the prompt prose is exactly what lets the bot answer from
`consultar_servicio('visa')`. One run each is not enough to call either stable.

**The replicated result is `reg-27486`**, measured on purpose because a headline of 60 cases cannot
see a single case move:
- live prompt: **1 green / 6 runs** (both of yesterday's runs, the stage-A baseline, two single-case
  reps, and the full baseline — the only green);
- candidate: **7 greens / 8 runs**.
In every baseline red the tool list is EMPTY and the failure is `no llamó calcular_usd`; in every
candidate green it calls `calcular_usd` and quotes 13,000. That is the amount-side precedence rule
doing the work, and it is the first thing in this feature to move the non-invocation failure at all.
An earlier claim in this session that "the stable red fell" was made on ONE rep and was wrong: the
second rep was red. The case is unstable in both arms, just overwhelmingly greener in the candidate.

### The CUP default is CODE, not prose — the real driver, one level below the prompt
Two of the three remaining reds (`reg-27065`, `reg-28021`) fail identically,
`llamó la PROHIBIDA calcular_envio`, and both answer with this, word for word:

> Por *30,000 GYD* llegan *90,000 CUP* a Cuba.

That sentence is not the model improvising, and it is not prompt line 116. It is dictated by the
**`Decisor` code node** of the production workflow (`jEzlVLCLUaJhVwzs`), which injects into the
context, precisely when the client asks how much arrives and NO rail was detected
(`!g83Destinos.length`):

> `CALCULO A HACER (ya resuelto por el sistema, no lo replantees): el cliente pregunta CUANTO LLEGA,
> o sea el monto que dijo es lo que EL DEPOSITA, en GYD... Usa calcular_envio con ese numero.
> Al responder di: "Por *X GYD* llegan *Y CUP* a Cuba."`

(The sibling branch does the same for `calcular_inverso` and "Para que lleguen *X CUP*...".)

This explains the whole history of this feature. The CUP default is asserted in the premise (105),
demonstrated in the template (116), AND ordered by code with "no lo replantees" attached, in exactly
the case where the rail is unknown — the case the owner's principle says must be a question. No
prompt can outrank an explicit system instruction in its own context, which is why three rule-level
fixes moved nothing and why line 116 looked like the lever: it is the same sentence in two places.
The remaining one lives in a node.

`reg-27065` and `reg-28021` are therefore correctly RED: their corrected expectations encode the
owner's principle, and they measure a defect the prompt cannot reach. The third red,
`reg-32635-calculo-desde-contexto`, is flaky (red in base, green in the invalid run, red in the
corrected one) and unrelated.

The queued fix is narrow and specific: the `Decisor` note must stop asserting a destination and stop
dictating the sentence — when no rail is known it should say the amount is what the client deposits
and that the destination must be asked. It is an n8n production change, so it needs the owner's
go-ahead and staging first, and it gets its own feature document. Nothing was touched.

### The owner found a FIFTH home of the CUP default, in my own candidate
He read one bot reply — `Hoy 1 GYD = *3 CUP*. ¿En qué moneda quiere que le llegue...?` — and named
the contradiction: giving the CUP rate already chooses CUP, and if something justified choosing it
then the question is redundant. Either you know and you do not ask, or you do not know and you do
not choose.

The culprit was **rule 2, which I carried forward verbatim** under "keep what works, untouched":

> `2. Tasa sin moneda: asume GYD: 'Hoy 1 GYD = *X CUP*. ¿Cuánto desea enviar?'`

It says *asume* and hands over a pre-filled CUP sentence — the same defect as lines 105 and 116,
which I had just removed, and which I then reproduced in THREE of my own worked examples (263, 379,
384). "Keep untouched" was a category I invented and applied without measuring; "I did not change
it" is not evidence that it works. That is also the answer to his "I feel like I am starting over":
the defect had several homes and I was finding them one at a time, so every fix looked like the bug
coming back.

#### Exhaustive sweep, so the count replaces the findings
Every surface that can speak to the model, swept at once instead of one at a time:

| surface | instances | state |
|---|---|---|
| prompt premise (105) + template (116) | 2 | removed in the candidate |
| prompt rule 2 + three rate examples | 4 | fixed now |
| `Decisor` quoting note + the `destino SIEMPRE CUP` comment | 2 | fixed, on staging |
| `Decisor` reparto note, "CUANTOS CUP recibe cada persona" | 1 | PENDING, see T8 |
| rest of the workflow | 0 | false positives: `Normalizar formato` ("se asume primer intento", retries), `Medir la semantica` (a telemetry comment), the four `Vision` nodes (Transfermovil screenshots that are NOT receipts), `cambiar_servicio` ("no, en CUP" as an example phrase) |

#### Owner's decision on the rate (2026-10-18), applied
Asked without naming a currency -> give BOTH rates that exist. Asked naming one -> only that one.
Rule 2 rewritten accordingly and the three examples now read
`Hoy 1 GYD = *3 CUP* y 1 USD = *260 GYD*.`

#### Measuring it exposed a second frozen layer in the battery
First measurement said the fix did nothing: 4 reps, CUP rate only. The prompt was not the problem —
**the battery mocks the tools**. `consultar_tasas` is recorded as ONE row,
`{"tasa": "1 GYD = 3 CUP"}`, while the live query returns TWO (verified read-only against
production: `1 GYD = 3 CUP` and `1 USD por Zelle = 260 GYD que deposita el cliente`). The bot could
not name a rate nobody handed it. With the mock corrected to the live two-row output: **4/4 green**,
answering exactly as the owner specified.

So the battery freezes August in TWO layers, not one: the baked `[CONTEXTO]` and the recorded tool
results. Both need regenerating from the real node and the real query before any further verdict —
and both are system output, mechanically derived, never a re-arbitration of `arbitrado: humberto`.

### Mining the real corpus: THREE contamination layers, and the column that solves it
The owner proposed tuning the prompt from production history instead of my judgement. He was right,
and it immediately beat everything I had reasoned — but the corpus is not minable naively, and three
separate traps each produce a confident wrong answer:

1. **`ai_generated=false` is NOT a human.** Messages flagged human include the bot verbatim:
   "Listo, su remesa fue completada. Gracias por confiar en nosotros.", "Su depósito de *26,000 GYD*
   ha sido verificado.", and even line 116's template, "Perfecto. Por *16,000 GYD* llegan
   *44,800 CUP* a Cuba." The team re-sends bot text from the panel. Mining this teaches the BOT's
   voice back and presents it as the team's.
2. **Not every `agent` message is customer service.** Much of it is the owner talking ABOUT a
   customer to a colleague, in tú: "Que veo que escribió ayer y le respondió el bot", "No le he
   podido poner un CUP a un cliente", "Le dices que Osmany Pozo". The `le` is third person.
3. **"Before the bot" is not clean either** — my own proposed fix, and it failed. Messages before
   2026-08-08 already say "le atiende el asistente virtual de *Remesas Ya*": an assistant existed
   earlier and its text is flagged human, because `ai_generated` only began being populated that
   day.

**The column that solves it is `sender_id`:**

| who | messages | period |
|---|---|---|
| bot (`ai_generated`, `sender_id` NULL) | 4,898 | 2026-08-08 -> today |
| **a logged-in person in the panel (`sender_id` NOT NULL)** | **2,864** | **2026-09-07 -> today** |
| unlabelled, before the author stamp | 2,840 | 2026-08-05 -> 2026-09-05 |

Authorship, not heuristics. Still worth excluding known bot templates on top, since a person can
paste them.

### The house voice, mined from the author-stamped set
| pattern | evidence |
|---|---|
| **"Serían X"** is THE quoting idiom | "Serían 135,200 GYD" · "Para 150 MLC serían 36,750 GYD" · "Para dolares en efectivo serían 290 por dolar" · "Serían 1000 guyaneses por cada 360 d saldo en Cuba" |
| **"enseguida"**, not "en breve" | "Enseguida le hacemos la transferencia" · "Enseguida le mando a poner el Zelle" · "Ya está comprobado, enseguida le ponemos su remesa" |
| **"poner"** is the verb for executing a send | "le ponemos su remesa" · "le mando a poner el Zelle" |
| apology without ceremony | "Disculpe la confusión" · "Gracias por su paciencia y una disculpa por la demora" |
| merchant voice | "lo tenemos a" · "La tenemos por" · "doy" · "cobramos" · "Esa la pondríamos por" |

And the cost of the robotic voice, written by the team to a customer:
**"No le hagas caso al bot que a veces tiene sus locuras."**

Added to the candidate as a `VOZ DE LA CASA` section — vocabulary to vary, explicitly NOT a new
template, since replacing a bad default with a rigid template is the mistake that produced the
mechanical rate reply in the first place. Two quote examples now use "serían".

Measured: 12/14 on the stage-A subset, identical to before the voice change, **zero regressions**.
The two reds are known and unrelated (`reg-27065` needs the regenerated context; `reg-32454` is the
tool-failure case, red in every run today). The prompt is now 57,014 chars, **+11.4% over the live
one** — the voice section and the rate rule cost that, and it is a real cost, not a rounding error.

Only the rate and the quoting idiom are done. The other ~35 examples are still my prose; rewriting
them from the author-stamped corpus is T10.

## Progress
- 2026-10-18: audit done. Rates confirmed as only gyd=3 and usd=260; six active services; five
  receive rails; the `mexico`/`saldo` mismatches found; six obsolete prompt items identified with
  line numbers, one of them measured as the actual driver (line 116).
