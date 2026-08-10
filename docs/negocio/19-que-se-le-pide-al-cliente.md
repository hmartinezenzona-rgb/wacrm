# Qué se le pide al cliente, y qué no se le promete

Cuatro cambios del **10 de agosto de 2026**, todos en el `Decisor` y en
`Contexto conversacion`. Salieron de leer una conversación real —la del cliente
`5927669918`— y **los cuatro se probaron mandando mensajes de verdad**, que es
lo único que los validó.

---

## 1. No preguntar la vía de depósito si el cliente ya depositó

El bot preguntaba *«¿desde dónde va a depositar, desde la app o con un agente?»*
a clientes que **ya habían depositado**. A uno se lo preguntó **tres veces**
teniendo el depósito verificado desde hacía una hora. Su respuesta fue *«esos
mensajes me confunden»*, y Osmany tuvo que entrar a mano.

**Medido:** 14 mensajes así a 8 clientes distintos en 5 días.

`Contexto conversacion` devuelve ahora `via_deposito_ya_usada`, sacada de las
notas del deal (`Via: Agente MMG`). Si hay depósito, el `Decisor` prohíbe la
pregunta **y le dice al agente por qué vía entró**, para que pueda responder si
el cliente pregunta por la cuenta.

**Se ata al ENVÍO EN CURSO, no a «algún depósito»:** un cliente puede abrir una
segunda remesa, y ahí la pregunta vuelve a ser legítima.

**Verificado contra datos:**

| | Mensajes | Clientes |
|---|---|---|
| Sin depósito → se mantiene (legítima) | 31 | 16 |
| Con depósito ya hecho → se suprime | 14 | 9 |

Ninguna pregunta legítima se pierde, y no por estadística sino por
construcción: sin depósito, `via_deposito_ya_usada` sale vacío.

---

## 2. Dos notas del contexto que se contradecían

Al probar la guarda de «no prometer la transferencia sin beneficiario», el bot
**la prometió igual**. No fue desobediencia: el contexto se contradecía.

```
[guarda nueva]  PROHIBIDO decir "en breve le hacemos la transferencia"
[nota anterior] ...la transferencia esta por hacerse... dile que sale enseguida
```

El modelo se quedó con la que prometía.

**La nota de `ESTADO REAL DEL ENVIO EN CURSO` ahora respeta la misma
condición**: si no se sabe a quién transferir, deja de decir *«está por
hacerse»* y *«sale enseguida»*. Cuando sí se sabe, el texto queda **idéntico al
de antes**.

> **La lección, que matiza la del día:** antes de culpar al modelo por saltarse
> una orden, hay que leer **todo** el contexto que le llega. Añadir una
> prohibición sin revisar si otra nota dice lo contrario no es un control: es
> una discusión que el modelo resuelve por su cuenta.

---

## 3. Pedir los datos en genérico hasta saber la vía de entrega

El bot pedía *«la tarjeta y el celular de quien recibe en Cuba»* nada más
recibir un comprobante, **dando por hecho que el envío era en CUP**. En la
conversación que lo destapó, el cliente iba a recibir por **Zelle**.

**Medido sobre los comprobantes reales del 10-ago** (solo ese día: los
`created_at` anteriores son el backfill de la `042` y no dicen cuándo llegó el
dato). De 15 comprobantes de clientes reales:

| Cuándo se supo a quién transferir | Casos |
|---|---|
| Ya se sabía al llegar el comprobante | 2 — la guarda ni dispara |
| **Llegó después** | **9** |
| Nunca llegó | 4 |

Y de esos 9, el tipo final fue **5 tarjeta cubana y 4 Zelle**. Casi mitad y
mitad: pedir «la tarjeta y el celular» habría sido la pregunta equivocada en
**4 de 9 casos reales**.

Ahora lo que se pide depende de lo que ya se sepa:

| Estado | Qué pide |
|---|---|
| No se sabe nada | *«¿Me pasa los datos de quien recibe?»* |
| Solo tarjeta | el celular |
| Solo celular | la tarjeta |
| Zelle a medias | lo que falte de la cuenta Zelle |

---

## 4. Para Zelle hacen falta nombre Y cuenta

Al probar la rama de Zelle **el bot volvió a prometer la transferencia**. La
causa era un error de la propia guarda:

```js
const sabeDestino = !!((tarjetaCtx && celularCtx) || s.datos_zelle || ...);
```

Con un Zelle **a medias**, `s.datos_zelle` ya era verdadero → `sabeDestino`
pasaba a `true` → **la guarda entera se saltaba**. La rama de «Zelle
incompleto» que había escrito **era código muerto: no podía ejecutarse nunca**.

Corregido: Zelle exige **nombre y cuenta**, igual que se exigen tarjeta y
celular.

```js
const zelleCompleto = !!(s.datos_zelle && s.zelle_nombre && (s.zelle_celular || s.zelle_correo));
const sabeDestino = !!((tarjetaCtx && celularCtx) || zelleCompleto || ctx.tiene_beneficiario);
```

---

## Cómo se probaron: las cuatro ramas, con mensajes reales

El `Decisor` **no se puede aislar en n8n** —depende de una docena de nodos
previos—, así que la prueba buena es reconstruir el estado en la conversación de
pruebas y mandar un comprobante de verdad.

**El estado se siembra en dos sitios:**

- `cerebro_beneficiario_parcial` (conversation_id, tarjeta, celular) — es de
  donde `Merge beneficiario` saca lo acumulado;
- los datos de Zelle **no** se siembran ahí: se detectan en el lote actual, así
  que hay que mandar el número **junto con** el comprobante, dentro de los 12 s
  del debounce.

**El comprobante que se usa:** el del **4-abr, TransID `20386475511192`,
30.000 GYD**. Es ideal porque está marcado `descartado_en` con el motivo
*«Anterior al arranque del sistema»*: **no es de ningún cliente y nadie lo va a
reclamar**. Lo único que impide que verifique es su antigüedad, así que se le
pone `recibido_en = now()` **solo a esa fila** —nunca se toca el umbral global
`cruce_antiguedad_max_horas`, que afectaría a comprobantes de clientes reales— y
se restaura al terminar:

```sql
UPDATE depositos_mmg
   SET deal_id=NULL, consumido_en=NULL, recibido_en='2026-04-04 13:48:06+00'
 WHERE trans_id='20386475511192';
```

**Y hay que mandar un fichero distinto cada vez**, o el hash lo para en
`Dedup comprobantes` y no llega al cruce.

**Resultados reales:**

| Estado sembrado | Lo que leyó el cliente |
|---|---|
| Nada | *«…ya quedó verificado. ¿Me pasa los datos de quien recibe?»* |
| Solo tarjeta | *«Me falta el celular de quien recibe en Cuba…»* |
| Solo celular | *«Ya me llegó el celular: 50806499. ¿Me pasa la tarjeta?»* |
| Zelle a medias | *«Falta el nombre del titular de la cuenta Zelle…»* |

Ninguna promete la transferencia, ninguna pregunta la vía, ninguna pide el dato
equivocado.

---

## El turno siguiente: por dónde pasan de verdad los clientes

Al probar las ramas se usó un atajo: mandar el comprobante y el dato de Zelle
**dentro de los 12 s del debounce**, para que cayeran en el mismo lote. Humberto
lo cuestionó: *«el comportamiento de los clientes rara vez será así»*.

**Y tenía razón.** Medido sobre los mensajes con imagen del 10-ago, cuándo llega
el dato siguiente del cliente:

| | Casos |
|---|---|
| **Dentro de 12 s (mismo lote)** | **1** |
| Entre 12 s y 2 min (lote nuevo) | 15 |
| Más de 2 min (lote nuevo) | 23 |
| No manda más datos | 12 |

**1 de 39.** El 97% de las veces el dato llega en un **lote nuevo**, sin
comprobante. Y ahí **la guarda del comprobante NO dispara**, porque su condición
es `s.comprobante && !sabeDestino`.

**Lo que cubre esos turnos es la nota de estado corregida**, que se emite en
todos los turnos mientras haya un envío abierto y sí depende de `sabeDestino`:

```
ESTADO REAL DEL ENVIO EN CURSO: el deposito YA FUE VERIFICADO...
OJO: TODAVIA NO SE SABE A QUIEN TRANSFERIRLE, asi que PROHIBIDO decir que la
transferencia sale enseguida...
```

Probado con la secuencia real —comprobante, respuesta del bot, y el número de
Zelle **en un lote aparte**—: el bot contestó *«Anotado el celular +1 (317)
903-7295 para la cuenta Zelle. ¿A nombre de quién está esa cuenta?»*, **sin
prometer la transferencia**.

> **Ojo al mantener esto:** la protección del caso mayoritario **no** es la
> guarda del comprobante, es el `if (est && !sabeDestino)` de la nota de estado.
> Si alguien lo quita pensando que es redundante, abre el agujero en el **97%**
> de los turnos.

---

## La regla que sale de aquí

**Una rama que no se ha visto producir un mensaje real no está probada.**

Los tres fallos más caros del 10-ago pasaron todas las comprobaciones previas y
solo aparecieron mandando un mensaje:

| Fallo | Qué lo escondía |
|---|---|
| Consulta rota, 27 min sin Cerebro | `PREPARE` validó una versión que no era la desplegada |
| El bot prometía la transferencia igual | dos notas del contexto se contradecían |
| La rama de Zelle no existía en la práctica | la condición de guarda la hacía inalcanzable |

Un dry-run demuestra **qué orden le llega al modelo**. Nunca demuestra qué
escribe. Son cosas distintas y hay que decirlas por separado.

---

## Reversión

| Cambio | Copia |
|---|---|
| No preguntar la vía | `ROLLBACK-v2-antes-no-preguntar-via.json` |
| La nota de estado no contradice | `ROLLBACK-v2-antes-estado-no-contradice.json` |
| Datos genéricos | `ROLLBACK-v2-antes-datos-genericos.json` |
| Zelle completo | `ROLLBACK-v2-antes-zelle-completo.json` |

Todos son cambios de parámetros: se aplican solos y no tocan datos.

---

## Lo que sigue sin resolver

**El sistema no sabe la vía de entrega.** Las 41 operaciones están tipadas como
`remesa`; `service_type` existe desde la `046` y **no lo rellena nadie**. Por eso
hay que preguntar en genérico: no es una preferencia de redacción, es que el dato
no existe.

Mientras siga así, tampoco se puede distinguir una **recarga** de una remesa —el
10-ago un depósito de 6.200 GYD para una recarga de Etecsa entró como *«Remesa»*—
ni CUP de Zelle hasta que el cliente lo dice.
