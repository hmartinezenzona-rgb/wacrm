# DB tools for the agent (staging only) - progress log

Owner direction 2026-10-22: the bot (LLM) creates operations and recipients with its tools; the automatic readers
(Registrar beneficiario auto, Registrar zelle auto, Registrar destino auto) are DISABLED on staging; "la solucion esta en
mejorar esa herramienta". Single DB writer: this log. The n8n agent codes against the signatures recorded below
("<n> applied on staging"). Nothing here is in production. Migrations 274+.

## Step 0 - audit of the disabled readers (read-only, live staging bodies, 2026-10-22)

Legend: OK = the agent tool covers it; GAP n = closed by the migration named in the last column.

| Reader node -> function | Writes (what / multiplicity / position) | Timing | Operation it targets | Agent tool | Coverage |
|---|---|---|---|---|---|
| Registrar beneficiario auto -> `cerebro_guardar_beneficiario_auto(conv, tarjeta, celular, tarjeta_acum, celular_acum, exec)` | One `cuban_card` recipient (card 16 digits, phone 8 digits, name never), partial data merged (a different card starts without phone, 179 D1); a vigente 2-3 slot reparto is patched by slot, never replaced (184) | Before the deposit only the COMPLETE pair (accumulated by Merge) opens a remesa; with an open operation, what arrived in this burst is saved at once (before or after the deposit) | `cerebro_resolver_operacion_beneficiario` (250 several-operations rule: amount, proximity, anchor, `misma_cuenta`); excludes visa/combo/saldo; unresolved with several remesas -> derives to a person | `gestionar_beneficiario` -> `cerebro_guardar_beneficiario(conv,nombre,tarjeta,celular,exec)` (p_op NULL) | Writes OK. GAP 6: target resolver is `cerebro_resolver_operacion` (service-blind, no 250 rule): in a mixed send / next to a recarga or Mexico operation the card lands on the wrong operation or the chat is derived (F: card on the recarga; 275/276) |
| same (combo branch) | nothing: an open combo collecting its recipients owns typed numbers | any | combo | `registrar_destinatario_combo` | OK |
| same (recarga branch) | Cuban phones with no card -> `crm_registrar_numeros_recarga(...)`: one `recarga` row per number, deduped, positions 1..n | open recarga, or declared recarga | latest open recarga | `registrar_numeros_recarga` | Writes OK. GAP 2/6: with another operation open and no recarga, the tool refuses with the resolver's "no alcanza" instead of opening the recarga part (F2); with a declared recarga and no operation it only works through `p_abrir` (276) |
| same (cash branch) | Cuban phone only on an `efectivo_usd` operation -> `crm_registrar_datos_entrega_efectivo(phone)` (one `efectivo_usd` recipient: name, phone, address, ID photo; merge by replacement) | after the cash rail is set | open `efectivo_usd` remesa | `registrar_datos_entrega_efectivo` | Writes OK. GAP 2: raises when no cash operation exists yet although the bot declared `efectivo_usd` (M3b) (275) |
| Registrar zelle auto -> `cerebro_guardar_zelle_auto(conv, nombre, cuenta, exec)` | ONE `zelle` recipient (holder, account); partial merge; a different account starts without holder; replacement per operation | Before the deposit only holder+account opens a remesa; with an open operation partial data saves at once | 250 resolver by account (`misma_cuenta`) | `registrar_beneficiario_zelle` -> `cerebro_guardar_zelle(conv,nombre,cuenta,exec)` (p_op NULL) | GAP 1: a second Zelle recipient REPLACES the first (C: Maria Lopez 'reemplazado'); GAP 6: no 250 targeting, service-blind (274, 276) |
| Registrar destino auto -> `cerebro_registrar_destino(conv, texto_completo)` | Reads the words: writes `cerebro_destino_pendiente` (clasica / tropical / cuban_card, last wins) and re-types the vigente card-rail recipients and `delivery_method` of the SINGLE open remesa, recalculates the destination amount (157) | any | single open remesa only | `marcar_destino_usd` (clasica/tropical/efectivo), `declarar_servicio`, `cambiar_servicio` | GAP 6: `cerebro_marcar_destino_usd` uses the same service-blind single-operation resolver: with a Mexico operation open it re-typed the Mexico operation to `efectivo_usd` (M3). No value for the CUP rail (276) |
| (not a reader, agent-only data) | Mexico recipient (CLABE/banco/titular or Coppel/BBVA retiro) | any | open `mexico` operation | `registrar_destinatario_mexico` -> `cerebro_guardar_beneficiario_mexico` | GAP 2: refuses when `mexico` was declared but no operation exists (M2, M3) (275) |
| (not a reader) | multi-service split of one deposit | after the deposit | holder operation | `repartir_envio` -> `cerebro_repartir_envio` | GAP 3: "No hay un deposito registrado" before the deposit (M3b); a deposit different from the parts is refused with only two sums (277) |
| (calculator side effect) | `cerebro_fijar_objetivo` from `calcular_usd` | at quote time | conversation | `calcular_usd` | GAP 4: "NO se fijo nada: sin beneficiario ni comprobante" before any recipient even after the bot declared a service (278) |
| (agent tool) | `agregar_servicio` / `cambiar_servicio` messages | any | resolver | `cerebro_aplicar_servicio` | GAP 5: `mensaje` NULL for `agregar` with `nueva_operacion` (F1) (279) |

Gaps found beyond the measurement list: (a) `marcar_destino_usd` retypes a Mexico/recarga operation (listed under 6);
(b) no `cup` rail value in `marcar_destino_usd` (default rail, closed in 276); (c) beneficiary tools derive to a person
whenever two operations are open (service-blind resolver) - the readers used the 250 rule, the tools did not (276);
(d) `registrar_numeros_recarga` cannot open the recarga part of a send while another operation is open (276).

Planned migrations (one coherent migration + ROLLBACK + assertion + commit each):
274 Zelle several recipients | 275 pre-deposit operations from the declared intent (mexico, cash, numbers, deposit attaches) |
276 service-aware target resolution for the recipient writers (mixed send, 250 rule for tools, marcar_destino cup) |
277 planned split before the deposit + facts on a different deposit | 278 objective without an operation |
279 `agregar` always answers a plain-Spanish `mensaje`.

