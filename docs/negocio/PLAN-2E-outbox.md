# Plan del tramo 2E — outbox de mensajes

**Escrito el 9-ago-2026. NADA DE ESTO ESTÁ APLICADO.**
SQL en `051_message_outbox.sql`, tampoco ejecutado.

---

## Por qué este tramo es distinto a los demás

2A, 2C y 2D fueron **aditivos**: tablas y triggers nuevos que nadie leía. Se
podían revertir con un `DROP` sin que nadie se enterara.

**2E toca el camino por el que sale una respuesta al cliente.** Es el primer
tramo que puede romper producción de verdad.

### Lo que hay que saber antes de tocar nada

**`Cerrar lote` tiene 10 rutas que desembocan en él.** Es lo que marca los
mensajes como procesados. Si se rompe: o quedan eventos atascados para siempre,
o el mismo mensaje se responde dos veces.

**Pero solo UNA de esas diez envía algo al cliente:** `Responder por WaCRM`.
Las otras nueve son silencios y descartes:

```
Avisar espera al cliente     Duplicado descartado      Replay descartado
Confirmar al admin           Hay lote?                 SKIP - no responder
Otro proceso tomara el lote  Silencio admin            Silencio por limite
```

**NINGUNA de esas nueve debe generar fila de outbox.** El cambio es local a una
rama de diez, no una reescritura.

### El estado actual de los dos nodos

```
Responder por WaCRM   httpRequest v4.4   POST https://wacrm.onlinefreedom.site/api/v1/messages
                      jsonBody: { to: telefono_e164, type: "text", text: output }
                      retryOnFail: NO    onError: NO      <-- de aqui viene el problema

Cerrar lote           postgres v2.6      SELECT * FROM cerebro_completar_lote($1)  [$execution.id]
                      retryOnFail: SI (3)  onError: continueRegularOutput
```

Hoy, si `Responder por WaCRM` falla: muere la ejecución → salta el manejador de
errores → libera el lote → se reintenta → **se llama otra vez al modelo**. El
cliente puede recibir dos respuestas, o una distinta de la que ya recibió.

---

## La clave de idempotencia: no repetir el error de 2D

En 2D se ancló la clave al `execution_id`, y resultó proteger menos de lo que
parecía: **un reintento de lote es una ejecución nueva**, con id distinto, luego
clave distinta.

Aquí el ancla es el **`whatsapp_message_id` del último mensaje del cliente
incluido en el lote**. Eso sí es estable entre reintentos, porque el reintento
procesa los mismos eventos.

```
idempotency_key = conversation_id || ':' || wamid_ancla
```

**Esto es lo más importante del tramo.** Si el ancla se implementa mal, el
outbox no sirve para lo único que tiene que servir.

Hay que sacar ese wamid del lote reclamado — mirar qué expone el `Decisor` o los
`session_events` de la ejecución antes de escribir la expresión.

---

## Despliegue en tres fases

### ✅ Fase 1 — outbox en sombra — APLICADA EL 9-AGO

Migración `051` aplicada y nodo `Encolar en outbox` añadido al Cerebro.
**Nada cambia para el cliente**: el envío sigue exactamente igual.

**El nodo va DESPUÉS de `Responder por WaCRM`, no antes** — y hay un motivo que
casi cuesta un incidente:

> `Responder por WaCRM` construye el mensaje con **`$json.output`**. Si se
> intercala un nodo Postgres antes, `$json` pasa a ser la salida de Postgres,
> `$json.output` queda `undefined` y **el cliente recibiría un mensaje vacío**.
>
> Poniéndolo después, el envío no se toca. Para la fase 1 —que solo quiere
> comprobar que se registra bien— es igual de válido. En la fase 3, cuando el
> envío desaparezca, el nodo pasa a ocupar su sitio.

Cadena resultante:

```
Respuesta valida?  →  Responder por WaCRM  →  Encolar en outbox  →  Cerrar lote
```

El nodo lleva **`onError: continueRegularOutput`**: si el encolado falla, **no
puede cortar la cadena hacia `Cerrar lote`**, o quedarían eventos atascados. En
sombra, lo que manda es que el flujo de siempre termine.

Las otras nueve rutas siguen entrando **directas** a `Cerrar lote`.

#### El ancla, resuelta mejor de lo previsto

No se pasa desde n8n: **la deriva la propia función** desde los
`session_events` que esa ejecución tiene reclamados:

```sql
SELECT max(whatsapp_message_id) FROM session_events
 WHERE processing_execution_id = p_execution_id
```

Así la clave depende de **qué eventos** se procesaron, no de quién los procesa
— que es justo lo que la hace estable entre reintentos. Y es un parámetro menos
que resolver con expresiones.

#### Verificado el 9-ago

| Prueba | Resultado |
|---|---|
| Mensaje real | 1 respuesta enviada, **1 fila** en outbox, 0 eventos pendientes |
| Clave generada | `40e6ab76…:wamid.PRUEBA.OUTBOX.1786313438` — el wamid real, sin caer al fallback |
| **Reintento** (mismos eventos, OTRA ejecución) | **no duplica**: *"ya estaba encolado"*, aunque el modelo generó un texto distinto |
| Mensaje nuevo del cliente | sí encola, fila aparte |

La tercera es la que 2D no conseguía, y la razón de ser del tramo.

> **Durante la fase 1, TODAS las filas se quedan en `pending` para siempre**,
> porque no hay enviador. Es lo esperado. **La consulta de "respuesta atascada"
> de más abajo NO aplica hasta la fase 3** — antes daría falsos positivos.

**Qué comprobar durante unos días:**

- que hay **una fila por cada respuesta enviada**, ni más ni menos
- que **ninguna de las nueve rutas silenciosas** genera filas
- que ningún `last_error` dice *"encolado sin ancla de wamid"* — si aparece,
  el ancla está mal resuelta y hay que arreglarla **antes** de seguir
- que dos ejecuciones del mismo lote producen **una sola fila** (forzar un
  reintento a propósito)

Mientras el Cerebro siga enviando, revertir es un `DROP` y no afecta a nada.

### Fase 2 — el enviador, apagado (riesgo: ninguno)

Workflow nuevo `Cerebro - Enviador del outbox`, **sin activar**:

```
Schedule (30 s)
  └─ Postgres: SELECT * FROM cerebro_outbox_reclamar(10)
       └─ HTTP POST a WaCRM  (onError: continueRegularOutput)
            └─ Postgres: SELECT cerebro_outbox_resultado($id, $ok, $error)
```

Probar contra la conversación de pruebas con filas metidas a mano. Verificar el
backoff (10 s, 30 s, 120 s) y que al cuarto intento marca `failed` y avisa en
el CRM.

**Con el enviador apagado y el Cerebro enviando, no hay riesgo de doble envío.**
Al encenderlo para probar, hacerlo con el Cerebro apagado o fuera de horario.

### Fase 3 — el cambio real (AQUÍ ESTÁ TODO EL RIESGO)

`Responder por WaCRM` deja de enviar y solo encola. El enviador envía.

**Con interruptor en `cerebro_config`** (`outbox_activo` = `si`/`no`) para poder
volver atrás sin desplegar.

**Requisitos innegociables:**

- [ ] Las plantillas de Meta **aprobadas** (ver más abajo)
- [ ] Fase 1 corriendo varios días sin una sola discrepancia
- [ ] **Domingo o madrugada**, con tiempo por delante
- [ ] Las 7 pruebas A-G de la Fase 1, repetidas enteras
- [ ] `ROLLBACK-v2-antes-outbox.json` guardado

---

## Por qué las plantillas van ANTES y no después

Un outbox que reintenta un mensaje fuera de la ventana de 24 h de WhatsApp
**reintenta algo que nunca se va a entregar**. Cuatro intentos, cuatro fallos, y
la fila acaba en `failed` habiendo hecho ruido para nada.

Con la plantilla aprobada, el enviador puede: intentar texto → si falla por
ventana cerrada, reintentar como `template`. Por eso `message_outbox` ya tiene
`message_type` con los dos valores desde el principio.

> **Verificar al llegar ahí:** cómo devuelve WaCRM el error de ventana cerrada.
> Si no se distingue de otros errores, el enviador no sabrá cuándo cambiar a
> plantilla. Eso hay que mirarlo en su API **antes** de escribir esa lógica —
> no suponerlo.

---

## Las 7 pruebas de aceptación, adaptadas al outbox

Las de la Fase 1 siguen valiendo. Lo que cambia es qué mirar:

| | Prueba | Qué debe pasar con outbox |
|---|---|---|
| A | Webhook duplicado (mismo WAMID) | una fila de outbox, un envío |
| B | Dos conversaciones, falla una | solo se reintenta la fila de A; B ni se toca |
| C | Dos lotes de una conversación | dos filas distintas, dos envíos |
| D | Error sin correlación | ninguna fila nueva, alerta crítica |
| E | PostgreSQL caído | el Cerebro no puede encolar → falla como hoy, sin duplicar |
| F | Máximo de reintentos | 10 s, 30 s, 120 s, y al 4.º `failed` + aviso en CRM |
| G | Ejecución normal | **el cliente recibe exactamente un mensaje, igual que hoy** |

**Dos pruebas nuevas, específicas del tramo:**

| | Prueba | Qué debe pasar |
|---|---|---|
| H | Matar n8n entre encolar y `Cerrar lote` | el enviador entrega igual; al reintentar el lote **no se duplica** (misma clave) |
| I | Las nueve rutas silenciosas | **cero filas de outbox** en todas |

La H es la razón de ser del tramo. La I es la que evita mandarle a un cliente
un mensaje que el sistema había decidido no mandar.

---

## Riesgo que asumimos y no se cierra aquí

El envío deja de ser inmediato: pasa a depender de un cron de 30 s. **La
respuesta al cliente puede tardar hasta medio minuto más.** Con un debounce de
12 s ya existente, va de ~45 s a ~75 s en el peor caso.

Es aceptable a cambio de no duplicar respuestas de dinero, pero **conviene
decírselo a Osmany antes**, no después de que lo note.
