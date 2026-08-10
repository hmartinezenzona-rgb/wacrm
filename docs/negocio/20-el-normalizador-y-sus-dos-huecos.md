# El normalizador de formato y sus dos huecos

Dos arreglos del **10 de agosto de 2026**. Salieron de una observación de
Humberto: *«la última respuesta del bot y otras más me salen como si no pasaran
por el normalizador»*.

Tenía razón, y había **dos causas distintas**.

---

## Lo que ya existía

`Normalizar formato`, en el Cerebro, mete saltos de párrafo en las respuestas
largas. Es determinista, sin IA y sin coste. Su principio innegociable:
**solo inserta saltos, nunca reconstruye**, y al final compara el texto sin
espacios contra el original — si no coincide, devuelve el original. Mejor mal
formateado que incompleto. Ver `13-normalizador-de-formato.md`.

---

## Hueco 1 — el notificador por etapa no pasa por él

`WaCRM - Notificar cliente por etapa del deal` (`wGud0KGR6eMqqfMQ`) es **otro
workflow**: manda sus mensajes directamente, sin tocar el normalizador.

El 10-ago se le añadieron mensajes nuevos y salieron así:

```
Su deposito de *7,777 GYD* ya fue verificado. Para poder hacer la transferencia
nos falta la tarjeta y el celular de quien recibe en Cuba. ¿Me los pasa?
```

**152 caracteres en una sola línea.**

**Arreglo:** el salto de párrafo va escrito en el propio texto. Se usa
`String.fromCharCode(10)` en vez de un literal, porque el `jsCode` viaja dentro
del JSON del workflow y las barras invertidas se deforman al subirlo — el mismo
problema que tumbó `Contexto conversacion` ese día (ver
`18-dos-caidas-silenciosas.md`).

> **Al añadir un mensaje al notificador, hay que formatearlo a mano.** No hay
> red que lo recoja.

---

## Hueco 2 — se retiraba ante un salto simple

La primera línea del normalizador era:

```js
if (txt.includes('\n')) return txt;   // el agente ya lo separo: no se toca
```

Daba por hecho que **cualquier** salto significaba que el agente había
formateado bien. Pero si ponía saltos **simples** en vez de línea en blanco, el
texto quedaba pegado y el normalizador no intervenía:

```
Buenos días, le atiende el asistente virtual de *Remesas Ya*.
Estamos fuera de horario pero por aquí le atendemos igual.
Su transferencia sale en cuanto abramos, a partir de las 9:00am.
```

**Arreglo:** solo se retira cuando hay **párrafos de verdad**.

```js
if (txt.includes('\n\n')) return txt;   // ya trae PARRAFOS de verdad: no se toca
```

---

## Cuánto pesaba, medido antes de tocar

Sobre los mensajes del bot del 10-ago:

| Formato | Mensajes | Largo medio |
|---|---|---|
| Con línea en blanco (párrafos) | 107 | 197 |
| Sin ningún salto | 79 | 75 — cortos, correcto |
| **Solo salto simple (queda pegado)** | **5** | 142 |

Y sobre todo el histórico desde el 8-ago: **15 mensajes** con salto simple y más
de 110 caracteres. Un 4%. No es una avería, pero es justo lo que se ve mal.

> **Dato que conviene tener presente:** 112 de 191 mensajes del 10-ago **ya
> venían con párrafos del propio agente**. El modelo formatea bien la mayoría de
> las veces; el normalizador es la red para el resto, no el que hace el trabajo.

---

## Cómo se verificó antes de desplegar

**Primero, tres mensajes reales entregados a clientes**, mandados al número de
pruebas en pares *antes / después* para verlos en WhatsApp como los ve el
cliente. No inventados: mensajes que se entregaron de verdad.

**Después, el histórico entero**: un banco de pruebas aparte con un nodo
Postgres que trae **los 349 mensajes** que ha enviado el bot, los pasa por el
nodo modificado y compara uno a uno.

| | |
|---|---|
| El normalizador los cambia | **30** |
| Los deja igual | 319 |
| **Dígitos alterados** | **0** |
| **Bloques de datos rotos** | **0** |
| Contenido alterado | 4 |

**Los 4 «contenido alterado» no son un fallo:** son las cuatro fugas de
razonamiento que quita el filtro del mismo nodo (`16-fugas-de-razonamiento-y-bucles.md`).
Ahí el contenido cambia a propósito.

Balance real: **26 mensajes mejor formateados, cero regresiones.**

Las dos comprobaciones que de verdad importaban:

- **ninguna cifra partida** — el riesgo era que `2.8 CUP` o `30,000` acabaran a
  caballo de dos líneas y el cliente leyera otro número;
- **ningún bloque de datos roto** — los `*Titular:* … *Cuenta MMG:* …` llevan
  saltos simples **a propósito**, y convertirlos en párrafos los estropearía.
  Están a salvo porque esos mensajes ya traen líneas en blanco entre bloques y
  siguen saliendo por la puerta temprana.

**Y en vivo**, tras desplegar:

```
Buenas tardes. Sí, estamos aceptando depósitos.

Para enviar *100 USD* necesita depositar *26,000 GYD*.

¿Cómo quiere que los reciba: por Zelle, en tarjeta Clásica o en Tropical? Y
dígame desde dónde va a depositar, si por la app o con un agente.
```

---

## Reversión

| Qué | Workflow | Copia |
|---|---|---|
| Párrafos en el notificador | `wGud0KGR6eMqqfMQ` | `ROLLBACK-notificador-antes-parrafos.json` |
| No retirarse ante salto simple | Cerebro | `ROLLBACK-v2-antes-normalizar-salto-simple.json` |

---

## Lo que esto NO arregla

**El formato y la redacción son problemas distintos.** Esto hace que el texto se
lea; que el texto **diga** lo correcto y suene bien es otra cosa, y esa sí toca
prompt. Queda pendiente.
