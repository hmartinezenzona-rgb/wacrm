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
- [ ] T4 Restructured prompt candidate, measured against the swept battery with a variance run
- [ ] T5 Staging, then production with the owner's go-ahead

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

## Progress
- 2026-10-18: audit done. Rates confirmed as only gyd=3 and usd=260; six active services; five
  receive rails; the `mexico`/`saldo` mismatches found; six obsolete prompt items identified with
  line numbers, one of them measured as the actual driver (line 116).
