# El `SKIP` que salió al cliente, y el orden de la tubería

**10 de agosto de 2026.** Un cliente (`5926109431`) recibió del bot un mensaje
que decía, entero:

```
SKIP
```

Lo vio Humberto leyendo el chat. Es el **único** de los 371 mensajes que ha
enviado el bot, y salió a las 18:05.

---

## Qué es `SKIP`

Es la palabra con la que el agente dice *«aquí no hay que responder nada»*: un
acuse puro del cliente («ok», «gracias») cuando hay una operación en curso. El
prompt es explícito: *«tu respuesta debe ser EXACTAMENTE la palabra SKIP, sola,
en mayúsculas»*, y un nodo `Respuesta valida?` la intercepta para que no salga.

**El agente hizo su trabajo bien.** Lo que escribió fue:

```
El cliente está repitiendo los datos de la cuenta Zelle que ya confirmé.
Ya están registrados y el depósito verificado. No hay nada nuevo que responder.

SKIP
```

---

## La causa real: el orden, no el modelo

La tubería estaba así:

```
Agente → ¿Respuesta válida? → Normalizar formato → Responder
              ↑ mira el SKIP        ↑ borra el razonamiento
```

El chequeo miraba el texto **con el razonamiento delante**. No empezaba por
`SKIP`, así que lo dejaba pasar. Después `Normalizar formato` quitaba el
razonamiento —haciendo exactamente lo que debe— y quedaba `SKIP` pelado, que se
envió.

> **Este fallo lo introduje yo esa misma mañana.** Antes de que existiera el
> filtro de razonamiento (ver `16-fugas-de-razonamiento-y-bucles.md`), ese caso
> habría enviado el párrafo entero: malo también, pero distinto. El filtro no
> creó el problema de fondo, **cambió el síntoma** — y lo hizo justo en el punto
> ciego del chequeo que estaba delante.
>
> La lección: **al meter un paso que transforma un texto, hay que mirar quién
> decide cosas sobre ese texto ANTES.** Un filtro nuevo no es inocuo por ser
> conservador; puede invalidar las decisiones tomadas río arriba.

---

## El arreglo

Invertir el orden. Sin código nuevo, sin nodos nuevos:

```
Agente → Normalizar formato → ¿Respuesta válida? → Responder
                                                 ↘ SKIP - no responder
```

Ahora el chequeo ve **el texto final**, que es sobre el que hay que decidir.

Y una guarda de más en el `IF`: **la última línea tampoco puede ser `SKIP`**.
Cubre el caso en que el razonamiento tenga una forma que el filtro no reconozca
y por tanto no llegue a borrarse.

```js
// tercera condicion del IF, ademas de "no empieza por SKIP" y "no esta vacio"
(($json.output ?? '').trim().split('\n').pop() || '').trim().toUpperCase() === 'SKIP'
   →  debe ser FALSE
```

**Lo que se comprobó antes de mover nada**, porque dos nodos de después
dependen de la cadena:

| Nodo | Cómo referencia | ¿Se rompe? |
|---|---|---|
| `Encolar en outbox` | `$('Normalizar formato').item.json.output` — **por nombre** | no |
| `Cerrar lote` | solo `$execution.id` | no |
| `Responder por WaCRM` | `$json.output` del nodo anterior | no, el `IF` pasa el item tal cual |

---

## Cómo se probó

Banco aparte con **el código real bajado del workflow**, no retecleado — la
lección que costó 27 minutos de producción esa misma mañana. Diez casos, **cero
fallos**:

| Caso | Esperado |
|---|---|
| Razonamiento + `SKIP` (el real) | callar ✅ |
| `SKIP` a secas, y en minúsculas con espacios | callar ✅ |
| **Razonamiento que el filtro NO reconoce + `SKIP`** | callar ✅ ← lo salva la guarda nueva |
| Vacío | callar ✅ |
| Razonamiento + respuesta de verdad | enviar ✅ |
| Respuesta normal larga y corta | enviar ✅ |
| Mensaje que menciona «skipear» | enviar ✅ |

**Y en vivo**, con un mensaje real al número de pruebas: la ejecución recorrió
`Agente → Normalizar formato → Respuesta valida? → Responder por WaCRM →
Encolar en outbox → Cerrar lote`, con `{"encolado": true}` y
`{"completados": 1}`.

---

## Una corrección sobre las fugas de razonamiento

Al investigar esto dije que habían salido **4 mensajes de razonamiento puro** que
el filtro deja pasar a propósito. **Era falso, y conviene que quede escrito.**

Los cuatro **sí llevan la respuesta detrás** de la línea en blanco: son
exactamente la forma que el filtro corta, y son **anteriores** a que el filtro
existiera. Medido sobre los 371 mensajes del bot:

| | |
|---|---|
| Empiezan razonando | **4** |
| …y llevan respuesta detrás (el filtro los corta) | **4** |
| …razonamiento **puro**, sin respuesta detrás | **0** |
| Último caso | 10-ago 12:00, antes del filtro |
| Mensajes enviados desde que el filtro está vivo | **104**, con **cero** fugas |

**El caso «el mensaje entero es razonamiento» no ha ocurrido nunca.**

### Qué hacer si algún día ocurre

Humberto descartó *callar*, y con razón: el cliente se queda sin respuesta y sin
que nadie se entere. La salida correcta no es el silencio ni la parrafada:

1. **Reintentar una vez.** Es barato y lo más probable es que la segunda salga
   limpia.
2. Si vuelve a salir sin respuesta, **pasárselo a una persona**: no enviar nada
   al cliente y crear un aviso en el CRM dejando el chat asignado. El cliente no
   queda colgado, y nadie lee el razonamiento interno del modelo.

**No está montado, y es deliberado**: mismo criterio que el fleco de la `062` y
que el vigilante por volumen de depósitos. Con cero casos reales, montarlo es
añadir superficie sin medir daño. Lo que lo dispararía es ver **un solo** mensaje
del bot que sea razonamiento sin respuesta detrás.

---

## Reversión

`ROLLBACK-v2-antes-skip-tras-limpiar.json`. Es un cambio de conexiones, así que
al revertir hay que **desactivar y reactivar** el workflow.
