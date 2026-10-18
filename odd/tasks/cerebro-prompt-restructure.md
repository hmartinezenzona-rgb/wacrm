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
- [ ] T2c Target SHAPE agreed before writing copy: rail chosen first and never assumed, CUP as one
      option among five, the pricing rule attached to each rail, and the services the bot can now
      sell listed as first-class rather than as exceptions
- [ ] T3 Sweep the gold battery for other expectations frozen before the USD rails, the way the
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

#### Scope of T2b, now that the shape is known
No longer "accept one more value". It is: `delivery_method` CHECK gains `mexico`; `rb_type_chk`
gains a Mexico recipient type; `cerebro_cambiar_servicio` accepts `mexico` and re-quotes it with the
single USD rate; the beneficiary parser and the panel learn the new type; plus the usual RED/GREEN
assertion, rollback and fingerprint, on a function that carries rail locks and audit rows. Its own
feature document, not a prerequisite tweak.

## Progress
- 2026-10-18: audit done. Rates confirmed as only gyd=3 and usd=260; six active services; five
  receive rails; the `mexico`/`saldo` mismatches found; six obsolete prompt items identified with
  line numbers, one of them measured as the actual driver (line 116).
