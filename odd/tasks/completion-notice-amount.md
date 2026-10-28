# The "remesa completada" notice always carries the amount when it is known

## Objective

When an admin completes a remittance, the customer's WhatsApp notice says what was sent ("Listo, su remesa de
*95 USD por Zelle* ya fue completada.") whenever the system knows the amount. Today it often goes without it.

## Problem (2026-10-28, read-only)

- The notifier n8n `wGud0KGR6eMqqfMQ` ("WaCRM - Notificar cliente por etapa del deal"), node "Buscar telefono",
  builds `{RECIBE}` only from `remittance_operations.quoted_destination_amount`. That column is empty when the
  bot never quoted the amount (the customer sent the deposit and the data directly).
- Completed in the last 30 days: 185; without `quoted_destination_amount`: 33.
  - 15 recargas/saldo (13 + 2): the notice ("su recarga ya fue realizada") has no amount by design. Unchanged.
  - 16 remesas: the amount is known, in the operation's calculator lines (written in the same transaction as
    the completion, so they are readable when the notifier runs) or in the vigente beneficiaries. Example:
    da96eada (2026-10-28) got "Listo, su remesa ya fue completada", with 95 USD on its beneficiary.
  - 1 in two currencies (ea834237, 30,000 CUP + 66 USD): stays without an amount, as the node's comment intends.
  - 1 with no data at all (5bf9e705): stays without an amount.
- The same `{RECIBE}` also feeds the "depósito verificado" notice ("Una vez hecha su remesa{RECIBE}..."), so the
  fallback helps there too (calculator lines do not exist yet at that point; beneficiaries may).

## Owner request

- 2026-10-28: "revisa lo pendiente por arreglar para el aviso de remesa completada".
- 2026-10-28: "si, aplicalo en produccion pero conviene que cuando sea saldo o recarga no diga remesa sino su
  servicio como tal".

## Scope

- Only the `recibe` subquery of "Buscar telefono" changes, in the production and staging notifier (same query
  in both). Fallback order: quoted amount (exactly as today) -> non-voided calculator lines in one currency
  (USD or CUP) -> vigente beneficiaries in one currency, all with an amount. Same number format, same currency
  wording ("USD por Zelle", "CUP", ...).
- Out of scope: filling `quoted_destination_amount` upstream; two-currency wording.

## Constraints

- Never execute the notifier (it sends real WhatsApp messages; staging shares production's token).
- n8n Postgres node: no `;` and no backslash inside the query text.
- Backup before every write; owner go-ahead for production.

## TDD

- Strict, on. Check: `pruebas/notificador/recibe-check.sql`, a read-only SELECT over production's completed
  operations of the last 30 days that compares the current and the new `recibe`. RED: the 16 remesas have no
  amount with the current query. GREEN: they get it, and every operation that had an amount keeps exactly the
  same text.

## Tasks

- [x] T1 New query in `pruebas/notificador/buscar-telefono.sql` (current one kept as `buscar-telefono.antes.sql`)
  + check `pruebas/notificador/recibe-check.sql`, run read-only on production (185 completed in 30 days):
  RED = 33 without amount today; GREEN = 16 filled (e.g. da96eada -> "95 USD por Zelle", dcb5199c -> "250 USD
  por Zelle" from the calculator, not the incomplete 200 of its beneficiaries), 169 identical, 0 changed among
  those that had an amount, 17 still without (15 recarga/saldo, ea834237 two currencies, 5bf9e705 no data).
  No `;` inside the text, no backslash.
- [x] T2 Staging notifier: replace the query; verify the node (no execution). PREPARE of the full new query on
  production with n8n's parameter types parses; EXECUTE (read-only) for da96eada returns "95 USD por Zelle".
  Staging `OCdJoHTkV6S0aAdk` da512d97 -> ed9fd561 == active; only "Buscar telefono" changed; connections equal.
- [x] T2b Service wording (owner's second request). "Filtrar cambio de etapa" copied to
  `pruebas/notificador/filtrar.jscode` (identical to production first) with `correr.ts` + `notificador.test.ts`:
  saldo gets its own verified/completed wording ("Listo, su saldo movil{RECIBE} ya fue enviado.") and asks for
  "el numero de Cuba"; the Meta template `remesa_completada` (fixed "su remesa de {{1}}") is attached only to a
  plain remesa, so saldo/recarga/combo/visa/Mexico outside the 24 h window go as text (Meta refuses them) until
  a service-neutral template is approved. RED 5 -> GREEN; all offline suites 278/278. Commit 18a187d.
  Staging ed9fd561 -> 5fb4d910 (only Filtrar changed this time).
- [x] T3 Production notifier after the owner's go-ahead; verify; snapshot. `wGud0KGR6eMqqfMQ` 3669da94 ->
  b2f22900 == active; changed exactly "Filtrar cambio de etapa" and "Buscar telefono"; connections and settings
  equal. Snapshot `infra/n8n/snapshots/notificador-b2f22900-20261028.json` (secret scan 0). Rollback: PUT of the
  3669da94 backup.
- [ ] T4 Watch the next real completion notice.

## Progress

- 2026-10-28 created. RDD off. Backups:
  `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/notificador-produccion-wGud0KGR6eMqqfMQ-3669da94-225e-428b-9daa-22ffa5d398e3-20261028-152913.json`,
  `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/notificador-staging-OCdJoHTkV6S0aAdk-da512d97-dd94-4992-947f-59f01f286ad3-20261028-152913.json`.

## Next step

- T4: read the next real completion and verification notices.
- Owner: whether to submit a service-neutral template to Meta (e.g. "Listo, ya completamos su {{1}}...").
