# Probar en staging: detalle

## Variables de fixture-envio.sql

Pasar TODAS con `-v` (vacia si no aplica). Valores validados en staging 2026-10-21 (ROLLBACK).

| Variable | Ejemplo | Nota |
|---|---|---|
| n | 0007 | 4 digitos; telefono 5990253nnnn; aborta si ya existe |
| nombre | envio mixto | contacto = `PRUEBA <nombre>` |
| svc1 | remesa / recarga | servicio de la operacion ancla |
| ruta1 | cuban_card / efectivo_usd | delivery_method y tipo de beneficiario |
| monto1 | 24400 | monto origen en GYD |
| estado1 | ready_to_transfer / collecting_information / awaiting_deposit | |
| moneda_dest / monto_dest | USD / 93 | moneda y monto de destino (el trigger recalcula si aplica) |
| con_beneficiario | 1 | beneficiario completo: nombre, tarjeta (si cuban_card) y telefono |
| deposito / deposito_consumido | 24400 / 1 | deposito PRUEBA en depositos_mmg; 1 = consumido por la operacion |
| objetivo | 1 | cerebro_objetivo_envio abierto por el monto de origen |
| svc2 / monto2 | recarga / 6200 | segunda operacion de la misma conversacion (envio mixto); vacio = ninguna |
| ultimo_mensaje | ya te envie el deposito | ultimo mensaje del cliente |

Caso simple: `svc2=` `monto2=` `deposito=0` `deposito_consumido=0` `objetivo=0`.

## Ejecucion

```
docker run --rm -i --env-file .env.staging postgres:17 sh -c 'psql -X -q -1 "$CRM_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -v n=0007 ... -f -' < assets/fixture-envio.sql
```

`-1` ejecuta el fichero en una sola transaccion. El NOTICE `fixture ok` da telefono, contacto, conversacion y operaciones.

## Limpieza

1. Vista previa (dry run): envolver en `BEGIN; ... ROLLBACK;` con `-v conv=<uuid>`. El NOTICE `limpieza:` muestra contacto, telefono, operaciones, beneficiarios y depositos que se borrarian. Ensenar al dueno.
2. Borrado real: mismo comando con `-1` y sin el ROLLBACK. Confirmar con `SELECT count(*)` = 0 por telefono.

El script rechaza cualquier contacto cuyo nombre no empiece por `PRUEBA`. Los depositos reales ligados a la operacion se desvinculan, no se borran.

## Panel

- Local: `infra/deployment/panel-local-staging.sh` (puerto 3100). Ruta de la bandeja: `/inbox`. Buscar la conversacion por el nombre `PRUEBA ...` o el telefono.
- Navegador: `new_page` en `http://localhost:3100/inbox`; el dueno inicia sesion. Despues `take_snapshot` y `click`/`fill`.
- Selects cuyo texto de opcion lleva espacios estrechos sin ruptura: poner el valor con `evaluate_script` y disparar `change`.
- Pestanas antiguas: Ctrl+Shift+R.
- Montos: escribirlos como el panel los formatea (separador de miles con punto) y leer el valor de vuelta en la base.
- `/api/promotions/etecsa` devuelve 500 en local (sin service key): esperado.

## Verificacion en base de datos (solo lectura)

```
SELECT o.service_type, o.status, o.quoted_source_amount, o.destination_currency, o.quoted_destination_amount, o.mixed_group_id
FROM remittance_operations o WHERE o.conversation_id = '<uuid>';
SELECT trans_id, monto, operation_id IS NOT NULL AS consumido FROM depositos_mmg WHERE asunto LIKE 'PRUEBA 5990253%';
SELECT action, field_name, before, after FROM remittance_admin_audit WHERE row_id IN (SELECT id FROM remittance_operations WHERE conversation_id = '<uuid>');
```

Confirmar que el bot no responde: la conversacion del fixture tiene `ai_autoreply_disabled = true`.
