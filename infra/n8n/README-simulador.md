# Simulador del Cerebro en staging

Un workflow **separado** que recibe un mensaje sintético y devuelve la respuesta del bot sin tocar
WhatsApp. No es el Cerebro de staging: ese comparte el token de producción y nunca se ejecuta.

## Por qué

El Cerebro real responde con `cerebro_outbox_encolar` + el enviador del outbox, que llama a la API de
WaCRM y de ahí a Meta. El simulador reemplaza **todo** camino de salida:

- `Encolar en outbox` → no-op.
- `Enviar directo?` → condición forzada a verdadero.
- `Responder por WaCRM` → INSERT en `messages` (la respuesta queda visible en el panel, sin enviar).
- `Resultado del envio`, `Despertar al enviador`, `Avisar espera al cliente`, `Confirmar al admin` → no-op.
- El webhook tiene un path aleatorio y exige `x-simulador-token`; el token vive en
  `~/.config/wacrm/simulador.env` (modo 600) y nunca se imprime ni se commitea.

## Crear o recrear

Después de un cambio en el Cerebro de staging:

```
python3 infra/n8n/crear_simulador.py
```

Clona el backup más reciente de staging, crea un workflow nuevo, lo activa y escribe
`~/.config/wacrm/simulador.env`. Cada ejecución crea un workflow nuevo: desactiva y borra el anterior
desde n8n o la API.

## Probar un turno

```
python3 infra/n8n/simular_cerebro.py --texto "Hola, cuánto llegan por 13,000 GYD a Zelle?"
```

Crea un contacto/conversación `PRUEBA` con el teléfono `59902539999` (o `--telefono`), inserta el
mensaje del cliente, firma el webhook, espera la respuesta en `messages`, la imprime y limpia las filas
`PRUEBA` (incluye expediente, outbox, ejecuciones, tool log, memoria y nonces del simulador).
`--conservar` deja la conversación para verla en el panel.

## Límites y seguridad

- Solo texto; las imágenes/audios no se simulan.
- Usa la base de staging y las credenciales del modelo; cada turno cuesta una llamada pequeña.
- **Nunca** ejecutar el Cerebro de staging ni el de producción.
- Si el Cerebro agrega un nodo de salida nuevo, hay que no-opearlo en `crear_simulador.py`; el
  `resultado` del 2026-10-26 lo demostró: la primera versión del clon no reemplazó el outbox y el
  número falso `59902539999` llegó a Meta, que lo rechazó con `#133010 Account not registered`. No
  era un cliente; la fila del outbox se borró y el clon se rehízo sin ningún camino de envío.
