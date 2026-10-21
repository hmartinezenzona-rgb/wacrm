# Investigar una conversacion: lectura de las secciones

Comando: `python3 infra/db/conversacion.py <consulta> [--desde YYYY-MM-DD] [--mensajes N] [--staging] [--elegir N]`.
Consulta: prefijo hex de id (>=6, con digitos y letras a-f), telefono (solo digitos, >=6) o nombre (letras, >=3).
Defecto: los ultimos 40 mensajes de produccion. Las fechas de las secciones son UTC.

## Secciones

| Seccion | Que es | Notas |
|---|---|---|
| CONVERSATIONS | Coincidencias (max 20) | Varias: lista y para. `borrada` = soft-deleted |
| MESSAGES | Ultimos N mensajes | `sender_type`: customer, agent. `[media]` = sin texto (foto, documento, contacto) |
| OPERATIONS | Operaciones de la conversacion | Mismo `GRUPO` = un mismo pago partido en varias operaciones |
| BENEFICIARIES | Beneficiarios de esas operaciones | Tarjeta solo ultimos 4 (`****1234`). `reemplazado` = historial, no vigente |
| AUDIT | `remittance_admin_audit` de operaciones y beneficiarios | Acciones `automation_*` = sistema; `human_*` = persona o agente del dueno |
| DEPOSITS | `depositos_mmg` ligados a las operaciones | `consumido` = ya asignado; `anulado`; `libre` = sin usar |
| CALCULATOR | `remittance_calculator_entries` de las operaciones | Solo se anade: `void` o `borrada` en vez de editar |
| TOOLS | `tool_execution_log` de la conversacion | Herramientas que ejecuto el bot; `outcome` vacio es normal |

`[num]` marca un numero largo enmascarado (tarjeta). Un id largo dentro de un texto no es un numero: los UUID no se enmascaran.

## Valores frecuentes

- `beneficiary.source`: `notes_parse` y `reparto_auto` = el sistema los creo a partir de notas o del reparto. `manual` y `admin_addition` = persona.
- `calculator.source`: `completed_operation` = generada al completar; `manual` = anadida a mano.
- `operation.status`: `ready_to_transfer` (listo para transferir), `completed`.
- Auditoria por actor: `claude-code:owner-request` = correccion pedida por el dueno.

## Chequeos frecuentes

1. **Quien guardo un beneficiario.** Mira `source` y AUDIT (`automation_*` frente a `human_*`). Una herramienta del bot con el mismo nombre en TOOLS no prueba la fuente: `notes_parse` y `reparto_auto` vienen del parseo automatico de notas.
2. **Calculadora.** Las lineas completadas son append-only. Un cambio de monto o base aparece como linea anulada y una nueva; no hay edicion silenciosa. Si una linea cambio sin fila en AUDIT, dilo como anomalia.
3. **Pago partido.** Operaciones con el mismo `GRUPO` suman un solo pago. Suma `ORIGEN` del grupo y compara con `DEPOSITS.MONTO` antes de concluir un faltante.
4. **Cierre manual.** `human_manual_close` con `delivery_mode: closed_manually` = cerrada sin aviso al cliente (`notify: false`).
5. **Respuesta del bot.** MESSAGES muestra lo que se dijo, no por que. Para el motivo, la ejecucion de n8n (`wacrm-cerebro-n8n`).
6. **Horas.** Todas en UTC; convierte solo si el dueno lo pide.

## Limites

- Produccion y staging tienen datos distintos; no mezcles ids entre ambos.
- El filtro `--desde` aplica a los mensajes; las demas secciones salen completas.
