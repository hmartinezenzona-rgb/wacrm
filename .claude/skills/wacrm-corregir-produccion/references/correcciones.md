# Correcciones en produccion: recetas y hechos

Hechos aprendidos en produccion (2026-10-19 y 2026-10-21). Antes de aplicar cualquier receta, comprobar el estado vivo con `pg_get_functiondef` o una consulta de lectura.

## Calculadora (`remittance_calculator_entries`)

- Las lineas completadas son append-only.
- `crm_corregir_entrada_calculadora(entry_id, facturado_gyd, invertido_gyd)` solo cambia facturado, invertido y retorno. No sirve para cambiar importe ni base.
- Para cambiar importe o base de una operacion completada:
  1. `UPDATE remittance_calculator_entries SET status = 'void', voided_at = now(), void_reason = '<motivo>' WHERE id = '<linea>';` (las cifras no se tocan).
  2. `PERFORM calculator_feed_operation('<operation_id>');`. Su upsert ON CONFLICT revive la fila void con las cifras nuevas. El indice unico es (account_id, operation_id, service) WHERE source = 'completed_operation', y ya incluye las filas void.

## Destino de una operacion completada

- El trigger no recalcula el destino de una operacion completada.
- Fijar a mano en la misma transaccion: `quoted_destination_amount`, `quoted_destination_origin = 'manual'` y `quoted_destination_rate`.
- Ajustar el importe del beneficiario vigente con `amount_origin = 'manual'`.

## Cierre manual silencioso

Un solo UPDATE, equivalente a `crm_cerrar_operacion_manual` con `p_notify = false`:

```sql
UPDATE remittance_operations
   SET status = 'completed',
       delivery_mode = 'closed_manually',
       delivered_by = '<user id del admin>',
       customer_notice_muted_for = 'completed'
 WHERE id = '<OPERACION_UUID>';
```

Completar dispara la alimentacion de la calculadora (trigger AFTER UPDATE OF status). Auditar con `human_manual_close`.

## Envio mixto

- Las operaciones de un envio mixto comparten `mixed_group_id` = id del ancla.
- `crm_repartir_envio` rechaza anclas completadas. Las completadas se corrigen a mano, con la receta de destino de arriba.

## Saldos CUP

- Preferir `crm_ajustar_saldo_cup(card_id, saldo_objetivo, motivo)`. Escribe filas `ajuste` en el ledger y una fila de auditoria `cup_cards` / `human_correction` / `balance_cup`.
- Aviso sin verificar: exige `is_account_member(account, 'admin')`, que depende del JWT del llamante. La API de Management API no envia JWT, asi que lo mas probable es un 42501. Antes de depender de ella, comprobarlo en staging (`wacrm-migraciones`).
- Si no funciona: UPDATE directo de lotes solo como ultimo recurso, con filas de auditoria y `ajuste` coherentes.

## Fuentes guardadas por el sistema

Los beneficiarios con `source` = `notes_parse` o `reparto_auto` los guarda el sistema, no la herramienta del bot. No tratarlos como dato introducido por el bot al investigar o corregir.

## Lectura posterior

Tras cada correccion, una consulta de lectura sobre las mismas filas. Anotar en engram solo ids y valores, nunca texto de clientes.
