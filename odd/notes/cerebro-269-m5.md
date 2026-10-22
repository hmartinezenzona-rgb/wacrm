# 269 / M5 staging (Cerebro agent side) - 2026-10-22

Staging workflow U52y1kSNvhgxvWeb only. Production untouched, workflow never executed.

## Done (version f74e9548 -> 0e362937, active = same)
- Backups: `~/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-f74e9548-...-151956.json` (before),
  `...-0e362937-...-152013.json` (after).
- Tools (Postgres tool nodes, staging credential, wired `ai_tool` -> Agente Remesas), builders in
  `pruebas/herramientas_269/herramientas.py`, applied by `aplicar_staging.py`:
  - `declarar_servicio(servicio)` -> `cerebro_declarar_servicio(conv, key, 'agent:declarar_servicio')`. It does NOT go
    through `cerebro_aplicar_servicio` with `p_intencion 'declarar'`: the resolver refuses that intent
    (265 R0 `intencion_invalida`, only cambiar|agregar). Declaring stores the intent; changing/adding executes.
  - `cambiar_servicio(servicio)` (existing node edited in place, was `cerebro_cambiar_servicio`) ->
    `cerebro_aplicar_servicio(conv, key, 'cambiar', 'agent:cambiar_servicio', exec)`.
  - `agregar_servicio(servicio)` (new) -> same with `'agregar'`, actor `agent:agregar_servicio`.
  - They return `mensaje` (DB plain Spanish), aplicado, permitido, motivo, minimo_gyd, faltante_gyd. Key normalisation
    only (`cup`->cuban_card, `efectivo`->efectivo_usd, `saldo movil`->saldo, `méxico`->mexico).
  - `registrar_numeros_recarga` now passes `p_abrir => true, p_actor => 'agent:registrar_numeros_recarga'`.
- Prompt (Agente Remesas `options.systemMessage`): the section `CAMBIO DE VIA` is replaced by `DECLARAR, CAMBIAR Y
  AGREGAR SERVICIO` (declare as soon as the customer states it, before paying; cambiar for a change of mind; agregar for
  an addition; never guess from receipt/amount/loose data; result handling by `motivo`), tool list and 2 few-shots
  updated, rule 10 reference updated. Backed by 18 offline tests (RED = module missing, GREEN after).
- SQL smoke (staging, one transaction, rolled back): the three queries and the numbers call run; `declarar mexico` and
  `cambiar mexico` return `servicio_invalido` until migration 273 (expected, no workaround).
- Albo leftovers: already absent from staging (no albo/clabe/spei/Humberto/mexico block in vision prompts, Historial
  contacto, Transcribir audio, Datos del negocio, Decisor). Nothing to remove.

## Blocked on 271/273 (not applied when this ran: rb_type_chk has no mexico types, no clabe/bank_name columns)
- `mexico` declarable/changeable: needs 273 (declarar/resolver/aplicar accept it).
- Recipient step for México (CLABE exactly 18 digits + bank + holder, or cardless withdrawal Coppel/BBVA + receiver
  name + phone) and removing the human handoff: no DB function exists, so no tool was added (a tool without its
  function would only fail). Needed DB side:
  - `cerebro_guardar_beneficiario_mexico(p_conv uuid, p_tipo text /* 'cuenta'|'retiro' */, p_clabe text, p_banco text,
    p_nombre text, p_telefono text, p_exec text) RETURNS jsonb` service_role only: finds/opens the conversation's
    `mexico` operation, validates CLABE ^[0-9]{18}$ (a CLABE never goes in card_number), retiro bank in (Coppel, BBVA),
    writes `remittance_beneficiaries` with beneficiary_type `mexico_cuenta`|`mexico_retiro` (clabe, bank_name, name,
    phone), merges partial data, returns `mensaje` + what is missing, audit actor `agent:registrar_destinatario_mexico`.
  - `cerebro_servicios.requiere_humano` for `mexico` -> false (and its message without "le paso con un operador") once the
    tool exists. Until then the prompt keeps following `consultar_servicio('mexico')` (handoff).
- When the function exists: clone `cambiar_servicio` node as `registrar_destinatario_mexico` (query
  `SELECT cerebro_guardar_beneficiario_mexico($1::uuid, $2, $3, $4, $5, $6, $7::text) AS resultado;`, fromAI: tipo,
  clabe, banco, nombre, telefono), add its line to the tool list and a MEXICO paragraph: ask for CLABE (18 digits),
  bank (Mercado Pago, Banco Azteca...) and holder, or Coppel/BBVA withdrawal (multiples of 100) with receiver name and
  phone; confirm in a block; no derivar_humano once the tool says complete.

## Risks
- 267 must not reach production before this prompt/tools (production constraint in service-resolution.md): production
  is still on the old design; this change is staging only.
- versionId == activeVersionId, but the in-memory-version trap is only ruled out by a later real execution (not run).
- A stray key `options.systemMessage` (old 44,964-char copy) sits in the Agente Remesas parameters; the live prompt is
  `options.systemMessage` (nested). Left alone.
