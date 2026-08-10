# Pendientes — Remesas Ya

Estado al **10 de agosto de 2026**, cierre de la jornada. Ordenado por lo que más
duele si no se toca.

> ## Lo que queda abierto, en una pantalla
>
> | | Qué | Depende de |
> |---|---|---|
> | 🔴 | **Rotar la API key de n8n y el PAT de GitHub** | de nosotros — es lo único rojo |
> | 🟠 | **La visión da por comprobante CUALQUIER imagen** | de nosotros — ver 10-ago |
> | 🟠 | **La rama de duplicados no consulta el cruce** | de nosotros — ver 10-ago |
> | 🟠 | **Migración 058:** borrar un deal deja la operación huérfana | de nosotros — la conciliación ya no da 0 |
> | 🟠 | **2E fases 2 y 3** (outbox) | plantillas de Meta, en revisión |
> | 🟠 | **Plantillas de Meta** | Meta (hasta 24 h) |
> | 🟠 | El agente no re-consulta un servicio en conversación viva | sin decidir |
> | 🟡 | **2F** — cortar `deals.notes` como fuente de verdad | sin prisa |
> | 🟡 | **Contabilidad y ganancias** — volumen ya hecho, falta el coste | **la hoja de Osmany** (`PEDIR-A-OSMANY-contabilidad.md`) |
> | 🟡 | Limpiar el Kanban y pantalla de historial | Hermes |
> | 🟡 | Combos, recargas automáticas y México completos | **37 preguntas a Osmany** |
> | 🔵 | Deuda de datos (10-16) y detalles menores | nada urgente |
>
> **Con fecha:** el **13-ago** empieza la promoción de Etecsa y el bot cotizará
> recargas solo por primera vez.
>
> **Nada de lo desplegado el 9-ago ha visto tráfico real de clientes** — era
> domingo. El lunes es la primera prueba de verdad; consultas de vigilancia al
> final de este documento.

**Cómo leerlo:** las secciones con 🔴 🟠 🟡 🔵 son lo que falta. Las que empiezan
con ✅ son cosas ya resueltas que se dejan escritas porque explican por qué el
sistema es como es — no hay que volver sobre ellas.

**Lo que YA está cerrado** (para no volver sobre ello): Fase 1 completa y en
producción con sus 7 pruebas de aceptación, punto 10 (secretos fuera de SQL),
HMAC de WaCRM al Cerebro, fijar y ocultar chats, CI encendido y en verde,
despliegue desde artefacto de CI, servicios del negocio, dólares enteros,
ventana de silencio, contexto de lo no visto, cruce de depósitos con plan B y
control de antigüedad, avisos de incidencia en el CRM, vigilante de mensajes
rechazados.

**Y de la jornada del 9-ago:** Fase 2 tramos **2A, 2B, 2C y 2D** completos y la
**fase 1 de 2E**; el bot callado en chats ocultos; traducción a 5.000 GYD;
servicios y los 76 USD de México verificados; sonido de incidencias cerrado;
promociones de Etecsa detectadas, confirmadas y anunciadas por el bot; pipeline
de Servicios; purga automática de logs; y n8n organizado en carpetas y
etiquetas. Migraciones **036 a 051** versionadas en el repo de WaCRM.

**Y del 10-ago (primer lunes con tráfico real):** una asignación de chat ya no
silencia al bot para siempre — migración **056**— y hay un vigilante que avisa
del cliente que se queda esperando — migración **057**. Por la tarde, dos
cambios en el Cerebro: **cuatro giros de visión** y **el contexto del
comprobante ya sale del veredicto del SQL**. Todo abajo.

---

## ✅ Cuatro giros de visión, y lo que le decimos al cliente (10-ago tarde)

Dos cambios en el Cerebro, los dos desplegados y verificados de punta a punta.
Detalle completo en `10-vision-doble-lectura.md` y
`14-lo-que-se-le-dice-al-cliente-sale-del-sql.md`.

### Los cuatro giros

Hasta hoy la imagen se leía dos veces, tal cual y girada 180. Ese conjunto
**depende de cómo venga la foto**: si el cliente la manda girada 90 grados, las
dos lecturas caen de lado y ninguna queda derecha. `{0, 90, 180, 270}` es el
mismo mire como mire la foto.

**Medido antes de construirlo**, 9 comprobantes reales con la referencia
confirmada en el libro:

| Cómo llega la foto | Dos lecturas | Cuatro lecturas |
|---|---|---|
| Derecha | 8/9 | 8/9 |
| **De lado** | **6/9** | **8/9** |

Con la foto derecha **no mejora nada**: todo el beneficio está en el caso de
lado. Cuesta **+6 s** por mensaje con imagen (3,5 s por llamada de visión).

De las lecturas equivocadas que producen los giros extra, **ninguna existía en
el libro** y las correctas sí: el árbitro filtra los candidatos malos.

> **Sorpresa útil:** la visión **sí** sabe leer texto de lado. El problema nunca
> fue que no supiera; era que con dos lecturas no se le daba la oportunidad de
> caer en una orientación buena.

Copia: `ROLLBACK-v2-antes-cuatro-rotaciones.json`.

### El contexto del comprobante

Por la mañana, un cliente mandó **una captura de un chat de WhatsApp** —no un
comprobante— y la visión leyó el número de cuenta `6762167` que aparecía en la
pantalla **como si fuera el importe**. El SQL lo marcó *"importe no está claro"*
y mandó el deal a Incidencia. **Y el bot le dijo igualmente al cliente
*"Recibimos su depósito de 6.762.167 GYD"*.**

La causa: el `Decisor` ordenaba **siempre** *"solo confirmalo al cliente"*,
pasara lo que pasara con la verificación, aunque el veredicto ya estuviera
calculado. Ahora la instrucción depende de `cerebro_cruzar_deposito`:
`verificado` confirma (texto idéntico al de antes), y `ya_reclamado`,
`deposito_antiguo` o cualquier otro acusan recibo **sin confirmar**. Si el
importe vino dudoso, **no se menciona ninguna cifra**.

Copia: `ROLLBACK-v2-antes-contexto-comprobante.json`.

---

## 🟠 La visión da por comprobante CUALQUIER imagen

**Lo de arriba tapó la herida, no la cerró.** El bot ya no le anuncia una cifra
falsa al cliente, pero **el deal fantasma se sigue creando**: la captura de chat
del 10-ago generó un deal de 6.762.167 GYD que sigue abierto e inflando el
panel de negocios abiertos.

El prompt de visión ya tiene un `CASO 4 - Cualquier otra imagen`, pero la
captura traía `6762167` y `Osmany Pozo`, que son literalmente el número y el
titular válidos del negocio, así que el modelo la clasificó como comprobante.

Por dónde iría: **un comprobante sin referencia no debería crear deal.** Si
`referencia = N/A` y el estado no es claro, lo honesto es no registrar nada y
derivar. Hay que mirar antes cuántos comprobantes legítimos llegan sin
referencia, no sea que se rompa un caso real.

---

## 🟠 La rama de duplicados no consulta el cruce

Salió probando lo anterior. Si el cliente reenvía la **misma imagen**,
`Dedup comprobantes` la para antes de llegar al cruce, y entra una rama del
`Decisor` que ordena *"acusa recibo de su comprobante"* **sin preguntarle a
nadie**. Observado: *"Recibimos su depósito de 39.000 GYD"* sobre un depósito
que llevaba consumido desde hacía una hora.

Es menos grave que lo anterior —el deal ya existía, no se mueve dinero— pero es
la misma enfermedad en un sitio donde no habíamos mirado.

> **Y de aquí sale un aviso para cualquier prueba futura:** reenviar una imagen
> idéntica **no ejercita el cruce**. Para probar esa parte hace falta una foto
> distinta, con otro hash.

---

## 🟠 Migración 058 — borrar un deal deja la operación huérfana

`cerebro_conciliacion_operaciones` **debía dar 0 filas siempre** y el 10-ago
llegó a **7**. Ninguna es un trigger roto: son deals borrados a mano desde el
CRM. `trg_sync_operacion_desde_deal` es `AFTER INSERT OR UPDATE`, **sin rama
`DELETE`**, así que la operación espejo se queda colgada.

Existe `trg_liberar_depositos_al_borrar_deal` (BEFORE DELETE), que sí libera los
depósitos — el hueco es solo la operación.

**Lo que hay que hacer:** rama `DELETE` que pase la operación a `cancelled` en
vez de borrarla, para conservar la auditoría, y una limpieza única de las que ya
están huérfanas.

**Por qué corre prisa aunque no rompa nada:** mientras la conciliación dé ruido,
**la red que avisa de fallos silenciosos de la Fase 2 no sirve**. Si mañana un
trigger falla de verdad, nadie lo va a notar entre las huérfanas.

> Relacionado con la **deuda 13** ("un deal desapareció el 7-ago"). Ya no es un
> caso aislado: el 10-ago se borraron varios a lo largo del día. Es
> comportamiento normal de operador limpiando el tablero, no algo automático.

---

## ✅ El bot mudo en los chats asignados (10-ago)

Lo encontró Humberto: al cliente **5926082754** el bot no le contestó nada en
toda la mañana. No falló nada — **20 ejecuciones seguidas** terminaron en
`{"ruta":"silencio","motivo":"chat asignado a humano"}`. El chat llevaba días
asignado a un operador y **una asignación no caducaba nunca**. Había **8 chats
más** igual de mudos, hasta de 4 días atrás, y nadie se enteró: un chat asignado
**no genera ninguna alerta**.

Arreglado con la migración **056** más la query del nodo `Contexto conversacion`:
pasados **10 minutos** sin actividad humana, la asignación **manual** se libera
sola. Se libera de verdad (no se ignora) para que dispare
`trg_limpiar_memoria_al_liberar`, que le deja al bot la marca *ATENCION HUMANA
YA TERMINADA*. El plazo se toca sin desplegar nada:

```sql
UPDATE cerebro_config SET valor = '15' WHERE clave = 'asignacion_caduca_minutos';
```

Dos trampas que costaron el rato y por las que el arreglo no es de una línea:

- **`conversations.updated_at` NO sirve de reloj**: se toca en cada mensaje,
  también en los del cliente. Con un cliente escribiendo, la asignación no
  caducaría jamás. De ahí la columna nueva `assigned_at`.
- **Las derivaciones del propio bot** (`derivar_humano` y el control de abuso)
  **no caducan**. Si el bot derivó fue porque no sabía seguir; retomar a los 10
  minutos sería peor que el problema que arreglamos.

Probado de punta a punta contra la conversación de pruebas (ejecución `26656`):
`asignado: false`, ruta `agente`, el bot cotizó y **no mencionó la derivación**.

Copia previa en `ROLLBACK-v2-antes-caducar-asignacion.json`.

---

## ✅ Vigilante de chats atascados (10-ago)

La 056 no cerraba el agujero entero, y esto es lo que más importa entender:
**la caducidad solo actúa cuando llega un mensaje nuevo**, porque quien libera
es una query del Cerebro. Un cliente que ya escribió y está esperando **no se
rescata solo**. Y las derivaciones del propio bot no caducan nunca, a propósito.

Migración **057**: workflow `Vigilante - chats asignados sin respuesta`
(`0nEQnuPE15UgRudW`), cada 5 minutos, un nodo Postgres llamando a
`cerebro_avisar_chats_atascados()`. Avisa **en el CRM** —nunca por WhatsApp, que
se realimentaría— cuando en un chat asignado el último mensaje es del cliente y
lleva más de 15 minutos sin respuesta de nadie. Solo en horario de atención: un
aviso a las 23:00 no lo lee nadie y entrena al equipo a ignorar la campana.

```sql
UPDATE cerebro_config SET valor = '20'  WHERE clave = 'chat_atascado_minutos';
UPDATE cerebro_config SET valor = '120' WHERE clave = 'chat_atascado_repetir_min';
```

**Avisa a todo el equipo, no al operador asignado**, y no por gusto: 
`notifications.user_id` tiene FK a `auth.users`, y las derivaciones del bot
escriben ahí un `profiles.id`. Insertarlo reventaría justo en el caso que más
importa vigilar. El responsable va en el cuerpo del aviso.

**Lo que encontró en la primera pasada** (ejecución `26727`, 3 atascados):
**Yunior llevaba 90 h esperando y Odessa 43 h**, sin que nadie les contestara
nunca. No sembré la tabla de deduplicación como en la 039 justamente por eso —
silenciarlos habría sido esconder el hallazgo. Segunda pasada: 0, el throttle
corta. Humberto liberó los dos a mano el mismo día.

**Y una corrección el mismo día, tras verlo fallar.** El tercer aviso era Lesa,
y era un falso positivo: Osmany le respondió y ella cerró con un `Okay` once
segundos después. No había nada que responder, y aun así el aviso se habría
repetido cada hora para siempre — justo lo que entrena al equipo a ignorar la
campana. Ahora **no avisa de un acuse puro** (`ok`, `gracias`, `thank you`, un
👍 suelto) cuando el mensaje anterior era de una persona.

> La guarda que sostiene todo eso es `content_type = 'text'`: una imagen o un
> audio **nunca** cuentan como acuse. Un comprobante sin respuesta tiene que
> seguir avisando. Verificado sobre datos reales con los tres casos —acuse puro
> 0 avisos, comprobante 1, pregunta de verdad 1— en un bloque que se revierte
> solo.

> **Para Hermes:** el tipo de notificación `chat_atascado` es nuevo. Si la UI
> pone icono o sonido por tipo, este no lo tiene. Es de la familia de
> `deal_incidencia`: alguien tiene que ir a mirarlo.

---

## 🟡 `derivar_humano` escribe un ID que la UI no resuelve

Salió mirando lo anterior. `derivar_humano` y el control de abuso escriben en
`conversations.assigned_agent_id` el valor `377b0c8c-…`, que es un **`profiles.id`**,
mientras que WaCRM escribe ahí el **`auth.users.id`**. Los chats derivados por el
bot quedan asignados a un usuario que la interfaz no sabe resolver.

Hoy nos viene bien —es lo que distingue las dos clases de asignación en la 056—
pero es una incoherencia real. Si se arregla, hay que cambiar a la vez el
discriminante de la 056.

---

## 🔴 Seguridad

| | Qué | Estado |
|---|---|---|
| 1 | ~~Token de GitHub de **Hermes** expuesto en Telegram~~ | ✅ **Revocado el 7-ago.** Sustituido por una **deploy key SSH** generada en el VPS: la privada no sale de la máquina y solo escribe en `wacrm`, no en toda la cuenta |
| 2 | **Revocar la API key de n8n** usada durante la Fase 1. Quedó escrita en la conversación | pendiente |
| 3 | **Rotar el PAT de GitHub de `~/.github-token`.** También quedó escrito en una conversación. **Sigue vivo y en uso** — con él se empujó al repo el 8-ago | pendiente |

Sobre el punto 2: revocarla me quita la capacidad de modificar workflows de
n8n. Para el siguiente cambio del Cerebro (el bot callado en chats ocultos)
haría falta una nueva. Se puede revocar ya y regenerar en ese momento —es un
minuto— o dejarla viva hasta entonces. Lo primero es más seguro.

Lo mismo vale para el 3: rotarlo corta mi acceso de escritura al repo, que es
por donde va el buzón de Hermes. Rotar y volver a escribir el fichero es un
minuto, pero hay que hacerlo a la vez.

**Criterio, ya aplicado tres veces:** los secretos se generan donde se van a
usar y solo viaja lo que no es secreto — la ruta de un fichero o una clave
pública, nunca el valor. Así se hizo con el secreto HMAC del Cerebro, con el
de `cerebro_config` y con la deploy key del VPS.

---

## ✅ Recargas: el bot ya informa, y cotizará solo desde el 13-ago (`047`–`049`)

Era el último servicio bloqueado por un dato que nadie tenía dónde consultar.

**Tres estados, y la distinción entre ellos es lo importante:**

| Situación | Qué hace el bot |
|---|---|
| Promo **vigente hoy** | cotiza y cobra (`requiere_humano = false`) |
| Promo **próxima confirmada** | **informa fecha y precio, pero NO cobra** |
| Ninguna | deriva, como siempre |

**El caso del medio lo detectó Humberto, no yo.** La primera versión solo miraba
promociones vigentes hoy, así que una confirmada pero futura era invisible: el
bot no podía ni decir *"empieza el 13"*. Y eso es exactamente lo que necesitaba
el cliente que el 9-ago se quedó cinco horas esperando por preguntar *"la
recarga del 13 al 16, ¿cuándo empezará?"*.

**Informar no es vender.** Con promo próxima, `requiere_humano` **no baja**:
hoy no se puede aplicar. Probado con el agente real, misma pregunta del cliente:

> *"La próxima promoción de Etecsa empieza el **13 de agosto** y dura hasta el
> **16**. Se recarga el mínimo de **600 CUP** y el cliente recibe **x6**, a un
> precio de **6,200 GYD**. Hoy todavía no se puede aplicar, pero apenas llegue
> la fecha la hacemos."*

La antelación es configurable (`promo_etecsa_avisar_dias_antes`, hoy **7 días**).

1. **`Vigilante - promociones de Etecsa`** (`vk6aEa4bOZtl5xSz`), cada 12 h: lee
   `www.etecsa.cu`, **descubre** el enlace de la promoción y lo parsea.
2. Promo nueva → se guarda como `detectada` y **avisa en el CRM** (tipo
   `promo_etecsa`).
3. Una persona la confirma. Hasta entonces el bot no la usa.
4. Con promo **confirmada y en fecha**, `cerebro_servicio_get('recargas')` le
   pasa al agente el precio y baja `requiere_humano` a `false`.

**No se tocó el prompt ni el workflow del Cerebro.** El agente recibe mejor
información por la tool que ya llamaba.

**El interruptor a automático** — ya construido, solo desactivado:

```sql
UPDATE cerebro_config SET valor='automatico' WHERE clave='promo_etecsa_modo';
```

**Estado:** promo confirmada por Osmany, 600–1250 CUP ×6, del **13 al 16**,
precio **6.200 GYD**. Hoy no está vigente porque empieza el 13; ese día se
activa sola.

**Vigilar que el vigilante siga vivo:**

```sql
SELECT valor::timestamptz AS ultima_revision, now() - valor::timestamptz AS hace_cuanto
  FROM cerebro_config WHERE clave='promo_etecsa_ultima_revision';
```

Si pasa de 2 días está roto. **No es grave:** sin promo vigente el bot vuelve a
derivar, como antes. Nunca cotiza con un dato viejo.

> **La URL no se fija nunca.** La actual es `/es/promo/internacional/sextup` —
> de *sextuplica*. La próxima será otra. El scraper descubre el enlace desde la
> home en cada pasada; fijarlo sería leer una promo caducada sin enterarse.

Detalle cosmético: el título sale como `"PROMOCIÓN INTERNACIONAL P"`, arrastra
una letra. No afecta a los datos.

**Pendiente de Hermes:** botón *"Confirmar promoción"* en la notificación. Hoy
la confirmación es SQL y **Osmany no ejecuta SQL**, así que la lanza Humberto.
Nota en el buzón (`2026-08-09-1930`).

---

## ✅ La traducción ya cuesta 5.000 GYD/hoja — aplicado el 9-ago

Osmany lo había fijado para el lunes; **Humberto decidió adelantarlo y se aplicó
el domingo 9-ago a las 17:00 UTC**. Queda anotado en `notas_internas` con la
fecha real y el `replace` inverso para revertir.

```
Cuesta 5,000 GYD por hoja ... cinco hojas son 25,000 GYD
```

**Verificado con el agente**, no solo en la tabla: *"cuesta 5,000 GYD por hoja.
Por 3 hojas serían 15,000 GYD"*.

La **visa** sigue en 4.000. Osmany dijo que sube "pronto" pero **sin fecha**, así
que no se toca hasta que lo diga.

> Nota sobre la fecha original: la nota decía "LUNES 11-AGO-2026", y el 11 de
> agosto de 2026 es **martes** — el lunes es el 10. La contradicción ya da igual
> porque se aplicó antes, pero conviene no volver a escribir una fecha sin
> comprobar el día de la semana.

### Y de aquí salió un fallo que no conocíamos — ver más abajo

Al probar el precio nuevo, el agente siguió cotizando 4.000. No era la tabla:
**no volvió a llamar a la herramienta**. Detalle en la sección siguiente.

---

## 🟡 Contabilidad: el volumen ya está, falta el coste

**Hecho el 9-ago (migraciones `052` y `053`).**

### Lo que se arregló de camino

**El dashboard del CRM mostraba el "valor de negocios abiertos" nueve veces
inflado**: 467.600 GYD cuando lo real eran 53.000. La causa era la deuda 10 —
nadie cerraba los deals, así que sumaba remesas entregadas hacía días.

Ahora **se cierran solas al llegar a "Entregada"** (y se reabren si salen de
ahí). Ya son 17 ganadas y 2 abiertas, y el dashboard dice la verdad.

### Lo que hay para consultar

| Vista | Para qué |
|---|---|
| `cerebro_resumen_volumen` | hoy / ayer / semana / mes / mes pasado |
| `cerebro_volumen_diario` | por día y por servicio |
| `cerebro_volumen(desde, hasta)` | informes a medida |
| `cerebro_historial_operaciones` | una fila por operación, como una hoja |

**El día es el día en Guyana**, no en UTC. Sin eso, a partir de las 20:00 local
el resumen contaría el día siguiente.

### Lo que falta y por qué está bloqueado

**La ganancia no se puede calcular.** `tasas` tiene un solo precio —el que se
le cobra al cliente— y **no existe en ninguna parte lo que cuesta poner ese CUP
en Cuba**. Igual con recargas y traducción.

**Esa es, casi seguro, la información que Osmany lleva a mano.** Su hoja no
duplica el CRM: tiene el dato que al CRM le falta.

**No se inventó una tabla de costes a propósito.** Sin saber cómo lo lleva
—tasa fija negociada, variable por día, con comisiones aparte— cualquier
estructura estaría mal y habría que rehacerla. Cuando exista el dato, la
ganancia es **una columna más** en las vistas de `053`.

Qué pedirle: **`PEDIR-A-OSMANY-contabilidad.md`** — una foto de la hoja y tres
preguntas. Deliberadamente corto: el cuestionario de 37 preguntas lleva sin
respuesta desde el 8-ago, y los cuestionarios largos no se contestan.

### ✅ La parte de Hermes, hecha y desplegada el 10-ago

**El Kanban ya filtra:** muestra abiertos, sin estado, y **entregados de los
últimos 7 días**.

> **No se nota todavía, y no es un fallo.** Todos los deals tienen menos de 7
> días porque el CRM abrió el 3-ago. Empezará a limpiarse **a partir del 13**.

**La pantalla `/resumen` está viva**, con enlace en el menú lateral. Lee las RPC
de la migración `055`. Verificado: devuelve 200 y los números cuadran.

> **Los datos NO se mueven ni se borran de ningún sitio.** La "limpieza" es un
> filtro en la pantalla; el historial completo sigue en la base.

**Dos cosas que salieron al montarlo y conviene no olvidar:**

1. **La pantalla se quedó sin desplegar 20 minutos.** El `Deploy` salió a las
   00:06 con el commit del Kanban, y el de la pantalla llegó a las 00:13. Un
   commit no es un despliegue: **hay que disparar el workflow después del
   último commit.**
2. **Filtra por `updated_at`, no por la fecha de entrega.** Si alguien edita un
   deal antiguo, reaparece en el tablero. Es defendible, pero es una decisión.
   Se verificó que el backfill del `052` **no** pisó esa columna — si lo
   hubiera hecho, el filtro habría quedado inútil una semana.

---

## 🟠 El agente no re-consulta un servicio dentro de una conversación viva

**Descubierto el 9-ago al cambiar el precio de la traducción.** Es la razón por
la que casi doy por bueno un cambio que no había llegado al cliente.

**Qué pasa:** una vez que el precio de un servicio está en la memoria de la
conversación, el agente lo repite de memoria y **no vuelve a llamar a
`consultar_servicio`**. Comprobado en las ejecuciones 25011 y 25015: respondió
*"4,000 GYD por hoja"* con la tabla ya en 5.000, y **ningún nodo de herramienta
llegó a ejecutarse**.

**Lo que hace que duela:** el prompt ya intenta evitarlo, con esta línea en
`## OTROS SERVICIOS`:

> *consultar_servicio se llama en CADA turno que mencione uno de esos servicios,
> tambien si ya se llamo antes en la misma conversacion.*

**No la obedece.** Al vaciar la memoria de la conversación (`cerebro_memoria`,
`session_id` = `conversation_id`) y repetir la misma pregunta, contestó 5.000 a
la primera. Es la memoria, no el prompt ni la tabla.

**Consecuencia:** un cambio de precio **no alcanza a las conversaciones que ya
están abiertas**. Con la ventana de 30 mensajes, una conversación activa puede
seguir cotizando el precio viejo un buen rato.

**Alcance real hoy: ninguno.** Se buscó el precio viejo en toda
`cerebro_memoria` y solo aparecía en la conversación de pruebas. Ningún cliente
tenía la traducción cotizada en memoria cuando se hizo el cambio.

**Qué hacer cuando cambie un precio de verdad** (recomendado, por orden):

1. Cambiar la tabla.
2. Mirar a quién le afecta y limpiar solo esas memorias:

```sql
-- quien tiene el precio viejo cotizado en memoria
SELECT session_id, count(*) FROM cerebro_memoria
 WHERE message::text LIKE '%4,000 GYD por hoja%' GROUP BY session_id;

-- y borrarlas: la conversacion sigue, solo pierde el contexto previo
DELETE FROM cerebro_memoria WHERE session_id = '<la conversacion>';
```

3. Verificar con una conversación **sin** ese dato en memoria. Preguntar en una
   que ya lo tenga **da un falso negativo**, que es exactamente lo que pasó aquí.

**Lo que NO arregla esto:** insistir más en el prompt. Ya está escrito de la
forma más explícita posible y no se cumple. Si esto llega a doler, la solución
es de flujo —inyectar los precios vigentes en el contexto de cada turno, como se
hace con `cerebro_conversacion_no_vista()`— no de redacción.

---

## ✅ Depósitos que no se confirmaban solos — arreglado el 8-ago

Un comprobante de 13.000 GYD se quedó en "Por verificar" y el cliente esperó
media hora. El correo de MMG había llegado bien: **la visión leyó mal 4 dígitos**
del TransID (`10397·6376·42163` en vez de `10397·3637·42163`), y el cruce exigía
igualdad exacta. Frecuencia medida: **1 de 13**.

Ahora, si el TransID no aparece en ningún correo, hay un **plan B**: se busca un
depósito con importe idéntico, dentro de la ventana horaria, sin consumir, con la
referencia de la misma longitud y mismo principio y final — y **solo si hay un
único candidato**. Si hay cero o dos, no se adivina. Al disparar se avisa al
admin para confirmación visual y queda anotado en el deal.

**Y de paso se cerró un hueco que salió al revisar las defensas:** el cruce
exacto **nunca miraba la fecha**. Había 80 depósitos sin consumir de más de 48 h
(2.066.560 GYD, el más viejo del 4-abr) y mandar hoy cualquiera de esos
comprobantes se verificaba solo y se pagaba. Ahora un depósito de más de **72 h**
no se consume aunque el TransID cuadre: va a Incidencia y lo mira una persona.

Ya estaba cubierto y no hizo falta tocarlo: la **misma imagen desde otro celular**
(el hash es clave única sin el teléfono) y el **mismo depósito con otra foto**
(el TransID solo se consume una vez → `ya_reclamado` → Incidencia).

Ficheros: `06-cruce-aproximado.sql`, `ROLLBACK-v2-antes-cruce-aproximado.json`.
Revisión: `SELECT … FROM deals WHERE notes LIKE '%COINCIDENCIA APROXIMADA%'`
y `… LIKE '%DEPOSITO ANTIGUO%'`. Umbrales afinables en `cerebro_config`
(`cruce_ventana_horas`, `cruce_antiguedad_max_horas`) sin migración.

---

## ✅ Hecho en la madrugada del 8-ago

| | Qué | Detalle |
|---|---|---|
| **Servicios del negocio** | El agente ya responde por combos, recargas, visa, traducción y envío a México | Tabla `cerebro_servicios` + tool `consultar_servicio`. Los datos NO están en el prompt: Osmany corrige un precio con un `UPDATE`. Ver `SERVICIOS-tramo1.md` |
| **Dólares siempre enteros** | Faltaba la dirección GYD→USD, así que el agente dividía solo y sacaba decimales | Nueva tool `calcular_usd_desde_gyd`. Las dos truncan con `floor`, nunca `round`: redondear arriba entregaría más de lo depositado. **La diferencia se la queda el negocio y no se le menciona al cliente** |
| **Ventana de silencio de 5 min** | Si una persona del equipo escribe, el bot calla 5 minutos y luego retoma solo | Corta en el `Decisor`, **sin llegar a llamar al modelo**. Depende del `ai_generated` que desplegó Hermes |
| **Contexto de lo no visto** | La memoria del agente solo guardaba lo que él mismo contestaba: al retomar tras una intervención humana repetía preguntas o contradecía acuerdos | `cerebro_conversacion_no_vista()` le inyecta lo que se dijo mientras callaba. Va como primera nota del contexto |

Todo probado en la conversación de pruebas, **incluida la regresión de remesas**,
que sigue idéntica. Respaldos: `ROLLBACK-v2-antes-servicios.json`,
`ROLLBACK-v2-antes-ventana-silencio.json`, `ROLLBACK-v2-antes-usd-entero.json`,
`ROLLBACK-v2-antes-contexto-humano.json`.

**Pendiente de Osmany:** `PREGUNTAS-OSMANY-servicios.md`, 37 preguntas. Sin sus
respuestas los combos no pasan de informar y derivar.

---

## ✅ Las conversaciones se rompían en el segundo mensaje — 9-ago

Al desplegar la tanda 3 salió un fallo del agente: `reasoning_content ... must be
passed back`. **No era del despliegue: estaba latente desde el 8-ago**, cuando
escribí la sección `## OTROS SERVICIOS` en prosa.

**La causa, ya conocida de dos veces anteriores (1 y 5 de agosto):** el lenguaje
deliberativo en el prompt activa el modo pensamiento de DeepSeek, y con una
herramienta de por medio la conversación se rompe en el turno siguiente.

Reescrita como mapeo plano y verificado: la secuencia que fallaba cuatro veces
seguidas ahora pasa. Detalle y la regla para el futuro en
`11-lenguaje-deliberativo-rompe-deepseek.md`.

**De rebote se comprobó algo bueno:** cuando el agente falla varias veces, el
sistema **asigna la conversación a un humano y se calla**. Funciona.

---

## ✅ Fotos giradas — resuelto la noche del 8 al 9-ago

Tres clientes en un día leídos mal, y el de Héctor iba a pagarse con **50.000 GYD
de menos** (2.000 donde ponía 52.000). La causa: los comprobantes son fotos de la
pantalla de otro teléfono y llegan giradas.

**Lo que no funcionó:** preguntarle al modelo en qué ángulo está. Con imágenes
derechas respondió 180 y 270, y al girarlas rompió lecturas perfectas. Probado
con dos modelos y varios prompts. Revertido.

**Lo que funciona:** leer la imagen **dos veces** —tal cual y girada— y elegir
preguntándole al libro de depósitos **cuál de las dos referencias existe de
verdad**. No opina, comprueba.

Probado con comprobantes reales en los dos sentidos: la boca abajo eligió la
girada, la derecha se quedó con la original. Detalle en `10-vision-doble-lectura.md`.

> **No meter bifurcaciones entre `Hash imagen` y `Parsear vision`.** La
> correspondencia entre imagen y resultado se mantiene por posición, y romperla
> registraría el comprobante de un cliente en la conversación de otro.

---

## ✅ RESUELTO — el agente se rompía al encadenar dos herramientas

**9-ago.** Era el fallo más grave que teníamos: con dos herramientas en el mismo
turno el bot moría y el cliente no recibía nada. Afectaba a **las remesas**, no
solo a los servicios: la pregunta *"¿a cómo está el cambio? ¿cuánto llega con 30
mil?"* lo disparaba.

**Arreglado** cambiando al nodo de la comunidad `n8n-nodes-deepseek-chat-model`
con el pensamiento desactivado. Mismo modelo, misma temperatura, mismo prompt.
Verificado con dos herramientas en un turno y cifras correctas.

Detalle, lo que no funcionó y los avisos: `12-el-modelo-no-debe-pensar.md`.

> **Riesgo nuevo:** dependemos de un paquete de un tercero. Si n8n arregla su
> incidencia `AI-2422`, conviene volver al nodo oficial y verificar de nuevo.

---

## ✅ VERIFICADO — sí, era el mismo problema. Los dos cerrados (9-ago tarde)

Eran las dos consecuencias del pensamiento del modelo. Con el nodo de la
comunidad ya no se reproduce ninguna. Probado en la conversación de pruebas,
**cuatro turnos seguidos, los cuatro `success`**:

| Turno | Qué se pidió | Herramientas | Resultado |
|---|---|---|---|
| 1 | *"a cómo está el cambio? cuánto llega si envío 30 mil?"* | `consultar_tasas` + `calcular_envio` | 84.000 CUP, tasa 2,8 ✅ |
| 2 | *"y para mandar a México? cuánto llega con 20 mil?"* | `consultar_servicio` + `calcular_usd_desde_gyd` | **76 USD** ✅ |
| 3 | *"por cuenta bancaria. y cuánto tarda?"* | ninguna | pidió CLABE, banco y titular ✅ |
| 4 | *"traducir 3 hojas? y hay recarga hoy?"* | `consultar_servicio` ×2 | 12.000 GYD, y **no se inventó la promo**: derivó ✅ |

**Lo de México está arreglado.** Dice 76 USD, no 77 — y se comprobó en la
ejecución que **llama a la herramienta** en vez de dividir de cabeza. Los 260
GYD por dólar salen de `tasas`, y el `floor` del SQL garantiza el truncado.

**Lo del turno siguiente también.** El turno 3 es exactamente el que rompía y
pasa sin tocarse. El turno 4 encadena **dos servicios** en un mensaje.

Ejecuciones: 24999, 25001, 25003 (y 24974/24976 de la regresión de remesas).

---

### (histórico: el diagnóstico de la madrugada, antes de dar con la causa)

**Estado al cerrar la madrugada del 9-ago.** Lo urgente está contenido, pero
esto no está resuelto.

### Qué pasa

`Agente Remesas` falla con:

```
Bad request — The `reasoning_content` in the thinking mode must be passed back
```

Se dispara cuando en el mismo turno se encadenan **`consultar_servicio` +
`calcular_usd_desde_gyd`**, y también en el turno siguiente a usar
`consultar_servicio` solo.

### Qué ya se descartó

- **No es la tanda 3**: se revirtió y siguió fallando.
- **No es general**: con `consultar_tasas` + `calcular_envio` —el flujo de
  remesas— dos turnos seguidos pasan sin problema. Probado.
- **No es solo mi justificación en el prompt**: se quitó el texto *"son 76
  dólares, no 77, porque redondear arriba entrega más de lo depositado"* y
  **volvió a fallar**. Queda algo más.

### Dónde seguir mirando

La sospecha es la **sección de servicios o el propio texto que devuelve
`cerebro_servicios.hechos`**, que es prosa larga y entra en la conversación como
resultado de herramienta. La hipótesis a probar: acortar los `hechos` y ver si
deja de dispararse. Ver `11-lenguaje-deliberativo-rompe-deepseek.md`.

### El impacto mientras tanto — acotado

- **Las remesas NO se ven afectadas.** Verificado.
- Un cliente que pregunte por servicios recibe una respuesta correcta y, si
  sigue escribiendo, **la conversación se deriva a una persona**. Nadie recibe un
  dato falso ni pierde dinero: se queda esperando atención humana, como antes del
  8-ago.

### Y un fallo de dinero pequeño, sin verificar

**México dice 77 USD por 20.000 GYD, cuando son 76.** Se movió el mapeo de las
calculadoras a `## TOOLS DE CALCULO`, que es la sección que el agente sí obedece,
pero **no se pudo verificar** porque la ejecución muere con el error de arriba.
Son 260 GYD por envío y solo afecta a México.

---

## 🟠 La ventana de 24 h de WhatsApp

> Lo urgente de esto **se cerró el 8-ago por la tarde**: ya no falla en
> silencio. Lo que sigue abierto es el riesgo de fondo, que afecta a clientes.

**Cómo se descubrió, el 8-ago, midiendo — no avisó nadie.** Desde el **7-ago a
las 03:43** todos los avisos al admin salían `failed`: derivaciones, incidencias,
fallos del Cerebro. **41 en total.** Nadie se enteró de ninguno.

**La causa:** WhatsApp solo permite texto libre dentro de las **24 h** siguientes
al último mensaje del destinatario. El admin (`5219622896918`) escribió por
última vez el 6-ago a la 01:06; la ventana cerró el 7-ago a la 01:06 y desde ahí
todo falla. Al escribir "." el 8-ago a las 15:20 se reabrió, y las alertas
volvieron a entregarse — confirmado con una de prueba.

Esto es **más grave que el fallo que se estaba arreglando**: el sistema avisa de
sus propios problemas por un canal que se apaga solo y en silencio.

### Lo que ya se hizo el 8-ago

- ✅ **Dejó de fallar en silencio.** Cron `Vigilante - mensajes que WhatsApp
  rechazó` (`rNN0LdHGTYUDOTfB`), cada 5 min, avisa **en el CRM** de todo mensaje
  que quede en `failed`. Ver `039_vigilante_mensajes_fallidos.sql`.
- ✅ **Las incidencias avisan también por el CRM**, que no depende de la ventana
  (`038_notificacion_deal_incidencia.sql`).
- ❌ Telegram: **descartado por ahora** por decisión de Humberto.

### Volvió a pasar el 9-ago — la prueba de que no está resuelto

Los 9 avisos de "FALLO EN EL CEREBRO" de ese día salieron **todos `failed`**, a
los tres admins. La ventana se había vuelto a cerrar sola.

**La diferencia con el 7-ago es que esta vez no fue en silencio:** el cron del
CRM (`rNN0LdHGTYUDOTfB`) los recogió. La mitigación funciona. Pero confirma que
el canal principal de alertas **se apaga solo cada pocos días**, y que hoy lo
único que lo tapa es que alguien mire el CRM.

### Lo que sigue abierto

**Plantillas de Meta para los mensajes al cliente.** Es lo único que arregla el
riesgo de verdad. El récord medido son **16,1 h** entre el último mensaje de un
cliente y un *"su remesa fue completada"*: quedan 8 h de margen antes de que un
cliente deje de enterarse de que su dinero llegó.

Lo bueno: **WaCRM ya sabe mandar plantillas** — su API acepta
`type: "template"` con nombre, idioma y parámetros. Lo que falta es de fuera:
dar de alta la plantilla en el gestor de Meta y esperar la aprobación. Como
**utilidad** (aviso transaccional) suele aprobarse rápido y sale barata.

Al implementarlo, **añadir sin sustituir**: se sigue mandando texto como
siempre, y la plantilla solo entra cuando el texto falla. Así, si la plantilla
está mal configurada, el peor caso es quedarse como hoy.

**Lo que NO hay que hacer:** que el admin escriba al negocio a diario para
mantener la puerta abierta. Funciona hasta el día que se le olvida, y ese día
no se nota.

---

## ✅ Sonido de incidencias — CERRADO, verificado con Humberto el 9-ago

**Hermes lo desplegó el 9-ago y se comprobó con Humberto delante:** suena, se
oye bien, y salta también el aviso de escritorio. El aviso en el CRM ya estaba
en producción desde el 8-ago; ahora tiene además sonido e icono.

Se disparó insertando una notificación real en `notifications` para los tres
usuarios (título `PRUEBA DE SONIDO`), y **las 9 filas de prueba se borraron
después**. Es la forma de probarlo sin tocar un deal ni mandar WhatsApp a nadie:

```sql
INSERT INTO notifications (account_id, user_id, type, title, body)
SELECT '465fb4ce-33b6-4473-ad2c-42818772f587', u, 'deal_incidencia',
       'PRUEBA DE SONIDO', 'se borra luego'
  FROM unnest(ARRAY['e3c7943d-b2fa-4c53-ae2f-406f1533ed47',
                    '5c4d16fd-1530-4023-8119-b58e04cc815f',
                    'ca797265-a1b3-43f7-9d9f-68c15d1f4780']::uuid[]) AS u;
-- y despues:  DELETE FROM notifications WHERE title LIKE 'PRUEBA DE SONIDO%';
```

> **Ojo con el bloque `DO $$ … RAISE EXCEPTION … $$`** que sirve para probar
> disparadores: aquí **no vale**. Al revertir la transacción la fila nunca llega
> a los suscriptores de realtime, así que no suena nada. Para esta prueba el
> `INSERT` tiene que confirmarse de verdad.

### Las dos primeras pruebas no sonaron, y no era el código

La causa final fue **la bocina en silencio**. Antes de dar con eso se verificó
toda la cadena midiendo, y conviene no repetir ese trabajo:

| Eslabón | Cómo se comprobó |
|---|---|
| Fichero desplegado | `ffmpeg volumedetect` sobre lo que sirve el servidor: 1,17 s, pico **-4,5 dB** ✅ |
| Servidor | `GET /sounds/incidencia-v2.mp3` → 200, `audio/mpeg`, 10.075 B ✅ |
| CSP | `media-src 'self'` lo permite, y va en *Report-Only* ✅ |
| Hook | correcto y montado en `dashboard-shell.tsx:27` ✅ |
| Realtime → evento | `use-unread-notifications` emite `wacrm:notification-insert` ✅ |
| Recepción | badge **y** aviso de escritorio, confirmado por Humberto ✅ |

**La pista que lo resolvió:** el aviso de escritorio SÍ salía. En el hook,
`playSound()` se ejecuta **antes** que `showDesktopNotification()`, así que si
se ve el aviso es que `audio.play()` se llamó. Eso deja fuera todo el código y
señala al audio de la máquina.

**Para la próxima vez que "no suene":** preguntar primero si sale el aviso de
escritorio. Si sale, el problema no está en el CRM.

### Y una cuarta ronda, ya de noche: sonaba cuando NO debía

Al recargar el CRM y hacer clic, sonaba el tono sin haber notificación.

**Causa: una extensión del navegador de Humberto.** El desbloqueo del autoplay
reproduce el tono silenciado y lo pausa; la extensión
(`page-script.js → player.replayAfterRemoval`) **detecta ese pause y lo vuelve
a reproducir**, cuando `muted` ya se había restaurado.

Se vio con un espía en la consola sobre `HTMLMediaElement.prototype.play`, que
mostró **dos** llamadas por clic: la del CRM con `muted: true` y otra con
`muted: false` desde la extensión. Confirmado en ventana de incógnito: **no
suena**.

**No se tocó el CRM.** Se valoró retrasar el `muted = false` unos 300 ms, y se
descartó: abriría una ventana con avisos mudos para arreglar una molestia de
una sola máquina.

> **Si alguien reporta que el tono suena sin motivo: preguntar por las
> extensiones del navegador antes de mirar el código.**

### Lo que enseñan las cuatro rondas

Ninguno de los cuatro fallos estaba en el código:

| Ronda | Causa real |
|---|---|
| 1 y 2 | el fichero a -29 dBFS — se vio **midiendo**, no escuchando |
| 3 | la bocina en silencio |
| 4 | una extensión del navegador |

Y ninguno se resolvió razonando: se resolvieron **instrumentando** —
`ffmpeg volumedetect` sobre el fichero servido, y un espía sobre `play()`.
Cuando un fallo se resiste a dos diagnósticos, deja de discutir con el síntoma
y ponle un instrumento.

Hicieron falta **tres rondas** porque las dos primeras salieron inaudibles, y
eso no se detecta escuchando: se confunde con "suena corto". Se resolvió
midiendo la amplitud del fichero, no describiéndolo con palabras.

| Ronda | Fichero | Pico medido | Resultado |
|---|---|---|---|
| 1 | `incidencia.mp3` (0,36 s) | 6,0 % (≈ -24 dBFS) | inaudible |
| 2 | `incidencia.mp3` (1,17 s) | 3,5 % (≈ -29 dBFS) | **más largo pero más flojo** |
| 3 | `incidencia-v2.mp3` (1,17 s) | **59,7 % (-4,5 dB)** | ✅ desplegado |

Commit `69563fd`, deploy verde (run `31293242109`), `GET /sounds/incidencia-v2.mp3`
→ 200. El **nombre nuevo** esquiva la regla de caché `s-maxage=300,
stale-while-revalidate=86400` del catch-all, que si no podía servir el tono flojo
durante horas.

**Lo único que queda: disparar la prueba con Humberto delante para que lo oiga.**
Hermes está esperando eso desde el 9-ago de madrugada.

**La regla que sale de aquí, y vale para cualquier tono futuro:** medir el pico
antes de desplegar. Un fichero por debajo de -20 dBFS no se oye en un móvil con
ruido alrededor, por larga que sea la duración.

Guía: `GUIA-HERMES-sonido-incidencias.md`, y en el buzón del repo los mensajes
`2026-08-08-1013`, `-1045`, `-1105` y los de la tanda del 9-ago.

Lo que se le insistió, porque es donde está el riesgo: el hook se monta en
`dashboard-shell.tsx`, que **envuelve todas las páginas del CRM**. Si lanza al
montarse, no se rompe el sonido — se rompe el CRM entero. Todo en `try/catch`,
comprobar que `Notification` existe antes de usarlo, y `.catch()` en el `play()`.
Y desplegar **fuera del horario del negocio**, porque el pipeline acaba en
`pm2-restart-wacrm` y WaCRM es quien recibe los webhooks de WhatsApp.

---

## ✅ Los depósitos por la app — resuelto la madrugada del 9-ago

**Descubierto el 8-ago.** La ingesta de correos estaba conectada a **un solo
buzón** —el del agente— y filtrando **un solo asunto**. Los depósitos por Pay
Merchant llegan al otro buzón, «Cuenta MMG», con asunto **`Payment Received`**.
Nunca entraban en el libro, así que esos envíos se quedaban en "Por verificar"
para siempre y Osmany los confirmaba a mano. **No es que el cruce fallara: ese
correo no existía para el sistema.**

Desde el 5-ago: **6 depósitos, 625.038 GYD**, ninguno en el libro. Y sube,
porque el bot ofrece la app como opción a todo el mundo.

La credencial ya estaba dada de alta desde el 3-ago (`2Ydg0vEfSSg8Vwog`) **sin
que ningún workflow la usara**, así que no hace falta pasar por Google.

**Desplegado y verificado.** La carga histórica trajo **318 depósitos** del buzón
de la Cuenta MMG (mucho más que los 6 que se habían medido: aquella cuenta era
solo desde el arranque). De esos, **314 son anteriores al 5-ago** y quedaron
descartados con el mismo criterio que los del agente; **4 son reales y quedan
pendientes**, 3 de ellos aún dentro de las 72 h.

Comprobado tras la carga: **cero settlements colados**, cero referencias no
numéricas, cero importes negativos, cero duplicados.

Ingesta en vivo activa: `4joVPN9jiXe0Z77Q`.

> **Ese buzón tiene cuatro tipos de aviso y solo uno es un depósito.**
> `MMG Settlement Initiated` es dinero que **SALE** hacia el banco. Recoger todo
> lo que venga de MMG sería un error caro — hay que filtrar por asunto.

---

## 🟠 Cerebro — riesgos abiertos

### ✅ 3. El bot ya calla en los chats ocultos — hecho el 9-ago

Ocultar un chat **ya calla al bot**. Antes no, y podía haber una conversación
entera —cotizando, pidiendo datos— invisible para el equipo.

Dos cambios en `Cerebro v2`, exactamente como estaban especificados:

- `Contexto conversacion`: columna nueva `(v.deleted_at IS NOT NULL) AS oculta`
- `Decisor`: `if (ctx.oculta) → ruta 'silencio'`, justo antes de `ctx.asignado`

**Las cuatro pruebas del documento, pasadas:**

| | Prueba | Resultado |
|---|---|---|
| 1 | Chat oculto + mensaje del cliente | **0 respuestas del bot** ✅ |
| 2 | El chat reaparece → el cliente escribe | responde normal, tasa 2,8 ✅ |
| 3 | Eventos en `processing`/`retry_wait` tras el silencio | **0** ✅ |
| 4 | Chat normal sin ocultar | igual que siempre ✅ |

Verificado en la ejecución 25195: `oculta: true` → `ruta: silencio`,
`motivo: 'chat oculto por el operador'` → `Silencio admin` → `Cerrar lote`.

**Por qué el "vuelve a funcionar" sale gratis:** WaCRM pone `deleted_at = NULL`
cuando entra un mensaje del cliente, **antes** de llamar al webhook. Cuando el
Cerebro lee el contexto —12 s después, por el debounce— la conversación ya está
visible.

*Límite conocido, aceptado:* si el operador oculta el chat con una ejecución ya
en vuelo y pasada la lectura del contexto, esa respuesta concreta sale igual.
Es una ventana de segundos.

Copia previa: `ROLLBACK-v2-antes-chats-ocultos.json`.

### 4. Tramo 2E — outbox de mensajes

Quedan dos caminos por los que un cliente puede recibir **la respuesta dos veces**:

- **Timeout de `Responder por WaCRM`** donde el mensaje sí se entregó. El nodo
  lanza, se reintenta el lote entero y se llama al agente otra vez.
- **n8n muere entre el envío y `Cerrar lote`.** El reaper rescata el lote a los
  10 minutos y el cliente recibe una segunda respuesta muy tarde.

El outbox lo cierra: la respuesta se guarda con su clave de idempotencia
**antes** de salir, el lote se cierra ahí, y un proceso aparte envía. Si el
envío falla se reintenta **el envío**, nunca el modelo.

*Ya mitigado:* el tercer camino (fallo del propio `Cerrar lote`) se cerró con
`retryOnFail` de 3 intentos.

### 4bis. El nodo de la comunidad a veces manda la llamada a herramienta como texto

**Visto una vez el 9-ago**, en la conversación de pruebas. El agente escribió el
tool call en crudo (`<｜｜DSML｜｜tool_calls>…`) y salió hacia WhatsApp como
mensaje, con estado `delivered` y la ejecución en `success`.

Buscado en **todo el histórico de `messages`**: **una sola vez, ningún cliente**.
Al repetir el mensaje respondió bien.

Es silencioso —no hay alarma que lo coja, porque para n8n la ejecución fue
correcta— y el cliente recibiría un churro en mitad de una cotización. Consulta
de vigilancia y el filtro que lo cerraría, en `12-el-modelo-no-debe-pensar.md`.

No cambia la decisión de modelo: el nodo oficial rompe la conversación entera en
cuanto hay dos herramientas, que es peor y mucho más frecuente.

### ✅ 5. Higiene del Cerebro — revisada el 9-ago

**Lo primero que salió al medir:** toda la base son unos pocos MB.

| Tabla | Filas | Tamaño |
|---|---|---|
| `depositos_mmg` | 661 | 944 kB |
| `cerebro_memoria` | 587 | 744 kB |
| `messages` | 972 | 672 kB |
| `session_events` | 426 | 344 kB |
| `cerebro_ejecuciones` | 296 | **160 kB** |

`cerebro_ejecuciones` "crecía sin límite" a razón de unos **12 MB al año**. Era
cierto y era irrelevante.

**Hecho — purga automática** (migración `045`): `pg_cron` habilitado y
`cerebro_purgar_logs()` programada los **domingos 07:00 UTC** (03:00 en Guyana,
negocio cerrado). Purga `cerebro_ejecuciones` a 30 días y `tool_execution_log`
a 90. Probada: devolvió 0 y 0, que es lo correcto con una base de 5 días.

**Decidido NO tocar, con motivo:**

| Qué | Por qué se queda |
|---|---|
| Los **4 nodos de modelo** sueltos (`DeepSeek Chat` oficial, `OpenAI Chat Model`, `Claude Haiku`, `DeepSeek Chat Model`) | **Son el mecanismo de rollback.** Volver atrás es mover un cable, y el 9-ago se usó `OpenAI Chat Model` para probar. Borrarlos quita esa salida |
| Nodo muerto `Silencio` (`noOp`) | Es basura real, pero un `noOp` **no consume nada** y quitarlo exige un cambio estructural del workflow con su desactivar/activar. Riesgo pequeño, beneficio cero |
| `cerebro_reintentos` (0 filas, huérfana) | Se conserva por si hay que volver al v1. Se borra cuando se jubile el v1, igual que el `?secret=` |
| `cerebro_memoria` | Es **lo que más crece**, y aun así no se purga: es la memoria del agente. Borrarla de una conversación viva le hace perder el contexto |

**`Esperar backoff` (120 s) sale de esta lista: no es higiene.** Mantener viva
una ejecución consume un slot de n8n, pero cambiarlo es un cambio de diseño de
los reintentos, no una limpieza. Con el volumen actual (~80 eventos/día) no
tiene ningún impacto medible. Si algún día lo tiene, la vía es apoyarse en
`retry_wait` y el cron de reintentos que ya existe, en vez de esperar dentro de
la ejecución.

---

## 🟡 Fase 2 — estado canónico por `operation_id`

**Arrancada el 9-ago.** El análisis está en `FASE2-ANALISIS.md` y el balance de
las tres fases del spec en `FASES-ANALISIS-COMPLETO.md`.

### 2A.1 — hecho el 9-ago (migración `040`)

`remittance_operations` en producción con **19 operaciones, una por deal**, y
**0 divergencias** en `cerebro_conciliacion_operaciones`.

**Nada lo lee todavía.** No se tocó ningún workflow, ni `deals`, ni las notas.
Cero cambios visibles para el cliente. Revertirlo es un `DROP` y no afecta a
nada.

Lo que entrega:

- **`cerebro_resolver_operacion(conversation_id)`** — la pieza que sustituye a
  `ORDER BY created_at DESC LIMIT 1`. Devuelve `unica`, `ninguna` o **`ambigua`
  con `operation_id` NULL**. Cuando hay dos operaciones vivas **no elige**: deja
  que el llamador pregunte o derive. Verificado forzando el caso.
- `cerebro_op_transicion_valida(desde, hasta)` — transiciones permitidas.
- `version` con control optimista, que sube sola en cada `UPDATE`.
- `cerebro_conciliacion_operaciones` — **debe dar 0 filas siempre**. Mirarla en
  cada despliegue de la Fase 2.

**Decisiones tomadas al hacerlo:**

- **No se creó `tenant_id`.** `deals` ya tiene `account_id` y es el eje de
  WaCRM; inventar otro obligaría a reconciliar dos ejes después. Cumple lo que
  pide la Fase 4 del spec usando lo que ya existe.
- **El backfill no parsea las notas.** Coge `deals.value` y la etapa, que son
  datos estructurados. Reconstruir desde texto libre es lo que esta fase viene a
  eliminar, y con 19 deals no compensaba el riesgo de leer mal.

> **Un fallo que cazó la prueba y conviene recordar:** la tabla de transiciones
> salió del spec, que supone una etapa `transferring`. **Este pipeline no la
> tiene** — de "Lista para transferir" se pasa directo a "Entregada". La primera
> versión rechazaba el camino real del negocio. Corregido antes de cerrar.
> El spec describe un flujo genérico, no este.

### 2A.2 — hecho el 9-ago (migración `041`)

La operación se mantiene sola a partir del deal. **`deals` sigue siendo la
fuente de verdad**; la operación es todavía un espejo que se rellena y no manda.

**Se hizo con un trigger sobre `deals`, no con nodos en el Cerebro.** Tres
razones, y la segunda es la que decidió:

1. No toca el workflow activo: sin ciclo desactivar/activar ni trampa de la
   versión en memoria.
2. **Captura también lo que hace un operador a mano.** Si alguien arrastra una
   tarjeta de etapa en el CRM, el workflow no se entera — el trigger sí. Con
   nodos, la operación se desincronizaría en cuanto alguien moviera un deal.
3. Se revierte con un `DROP TRIGGER`, sin desplegar nada.

El patrón ya existía en esta base: `trg_notify_deal_incidencia` (038).

**Probado en bloques revertidos, 8 casos:** deal nuevo crea su operación; mover
de etapa sincroniza el estado; cambiar el importe se refleja; **deal de otro
pipeline se ignora**; **deal sin `conversation_id` se ignora**; operación
borrada a mano se recrea al tocar el deal; conciliación en 0; y el rollback
dejó la base igual que antes (19 y 19).

Las dos guardas de exclusión se probaron **fabricando un pipeline de prueba**
dentro del bloque revertido, porque hoy solo existe uno y si no habrían quedado
sin verificar.

**Lo que el trigger NO pisa:** `delivery_method`, `deposit_method` y
`quoted_destination_amount`. Son más ricos en la operación que en el deal y los
llenará 2C/2D.

> **Falla en silencio a propósito.** Lleva `EXCEPTION WHEN OTHERS` porque un
> fallo del espejo no puede impedir que se cree o se mueva un deal — es dinero.
> Las dos redes que lo cubren: `cerebro_conciliacion_operaciones` deja de dar 0
> filas, y queda un `RAISE WARNING` en el log de Postgres.

### 2C.1 — hecho el 9-ago (migración `042`)

Los beneficiarios salen del texto libre a `remittance_beneficiaries`:
**13 filas — 8 Zelle y 5 tarjeta cubana**, exactamente los 13 deals que tienen
bloque `BENEFICIARIO` en notas.

**La auditoría de correcciones funciona.** Una corrección no borra: el
beneficiario nuevo queda `vigente` y el anterior `reemplazado`, con su
`replaced_at`. Probado añadiendo una tarjeta nueva a un deal real: quedaron las
dos filas, `0025:reemplazado, 6666:vigente`.

**Los formatos no se dedujeron de los datos**, se leyeron de las querys de las
cuatro tools que los escriben. Reconoce los siete encabezados que existen,
incluidos `(auto)` y los `ACTUALIZADO`.

`ENTREGA EN USD: Clasica|Tropical` no va a esta tabla: no es un beneficiario,
es **cómo** se entrega, y va a `remittance_operations.delivery_method`.

Mismo patrón que 2A.2: trigger sobre `deals`, captura también las ediciones a
mano, y falla en silencio con `WARNING` para no tumbar el flujo del dinero.

### 2C.2 — hecho el 9-ago (migración `043` + 5 nodos del Cerebro)

**La deuda 14 está cerrada.** Las cinco escrituras que cogían *el deal abierto
más reciente* ahora resuelven con `cerebro_resolver_operacion()`:

`gestionar_beneficiario`, `registrar_beneficiario_zelle`,
`registrar_reparto_multiple`, `marcar_destino_usd`, `Registrar beneficiario auto`.

| Caso | Antes | Ahora |
|---|---|---|
| Un envío abierto | escribe en él | igual |
| Ninguno | crea envío nuevo | igual |
| **Dos o más** | **escribía en el más reciente** | **no escribe nada y deriva** |

Verificado en producción con dos operaciones vivas: no se creó un tercer envío,
las notas no se tocaron, el beneficiario nuevo **no se registró en ninguna
parte**, y la conversación quedó asignada a una persona.

> **El primer intento falló, y la lección vale más que el arreglo.**
>
> La versión 1 solo devolvía un texto de error a la tool. Se probó y **el modelo
> lo ignoró**: le dijo al cliente *"Anotado, cambio la tarjeta"* cuando no se
> había guardado nada. Eso es **peor** que el fallo original — no corrompe
> datos, pero le miente al cliente.
>
> La versión 2 **asigna la conversación por SQL**, dentro de la misma query. El
> efecto ya no depende de que el modelo obedezca. Después el `Decisor` ve la
> conversación asignada, corta sin llamar al modelo y cierra el lote.
>
> **Regla que sale de aquí:** un mensaje de error a una tool NO es un control.
> Si algo tiene que pasar sí o sí, tiene que pasar en el SQL.

**El filtro de estados importa:** las tools usan
`ARRAY['collecting_information','deposit_verification','ready_to_transfer']`,
que son exactamente los tres stages que aceptaban antes. Sin ese filtro habrían
empezado a escribir sobre envíos en **Incidencia**, que hoy no tocan.

> **Y un fallo de orden de triggers que cazó la prueba** (migración `043`):
> Postgres dispara los `AFTER INSERT` **en orden alfabético de nombre**, y
> `trg_sync_benef...` iba antes que `trg_sync_operacion...`. El de beneficiarios
> corría cuando la operación **aún no existía**, no encontraba a qué colgarlos y
> salía sin hacer nada, en silencio. **La conciliación no lo detecta**, porque
> compara operaciones contra deals, no beneficiarios. Arreglado por dos vías a
> la vez: el trigger de operaciones ahora sincroniza beneficiarios al final, y
> además el otro se renombró para quedar después.

| Tramo | Qué | Estado |
|---|---|---|
| **2A** | `remittance_operations` + resolutor + backfill + escritura dual | ✅ **hecho 9-ago** |
| **2B** | **Depósitos + hash transaccional** | ✅ **hecho** |
| **2C** | Beneficiarios + auditoría + tools sin "el más reciente" | ✅ **hecho 9-ago** (`042`, `043`) |
| **2D** | `tool_execution_log` + idempotencia | ✅ **hecho 9-ago** al segundo intento (`044`) |
| **2E** | Outbox — **fase 1 (sombra) hecha 9-ago** (`051`) | 🟠 faltan fases 2 y 3 |
| 2F | Renderizador de notas + cortar la fuente de verdad | pendiente — **sin prisa** |

### 2E — dónde está exactamente

**Fase 1 aplicada:** el Cerebro encola cada respuesta en `message_outbox`
**después** de enviarla, y sigue enviando como siempre. El cliente no nota nada.
Sirve para verificar la clave de idempotencia con tráfico real antes de que el
outbox mande de verdad.

**Falta:** el enviador (fase 2, sin riesgo) y el cambio de quién envía (fase 3,
donde está todo el riesgo). **La fase 3 necesita las plantillas de Meta**, que
están en revisión.

Plan completo, pruebas y advertencias: **`PLAN-2E-outbox.md`**.

> Durante la fase 1, **todas las filas del outbox se quedan en `pending` para
> siempre** porque no hay enviador. Es lo esperado, no un atasco.

### ⚠️ 2D — intentado el 9-ago, ROTO y REVERTIDO

**Estado: nada de 2D queda en el sistema.** Se revirtió el workflow y se borró
`tool_execution_log`. El sistema está como al cerrar 2C.

**Qué se rompió:** el nodo `Registrar beneficiario auto` empezó a fallar con
`could not determine polymorphic type because input has type unknown`. Causa:
`to_jsonb($2)` sin cast. Postgres no puede inferir el tipo de un parámetro
suelto ahí. Faltaba `to_jsonb($2::text)`.

**Impacto: ninguno en clientes.** Tres ejecuciones fallidas entre 18:36 y 18:38
UTC, todas de la conversación de pruebas. **Cero mensajes de clientes reales**
en esa ventana (domingo por la tarde, negocio cerrado). Revertido a las 18:38 y
verificado con un mensaje real.

#### Las dos lecciones, que valen más que el arreglo

**1. Validar una query "representativa" no vale.** Se montó una validación con
`PREPARE` de las cinco queries y luego se ejecutó **solo una**, razonando que
si la transformación era idéntica, valían todas. Es falso: la transformación
era la misma, pero **el contexto de tipos de cada query no**. En
`marcar_destino_usd` el `$2` iba dentro de un `lower()` que lo tipaba; en la
ruta automática no había nada que lo tipara.

> **Regla: si se monta la validación, se ejecuta entera.** El atajo se tomó
> para ahorrar contexto y costó una rotura en producción.

**2. Mirar qué ruta se ejecuta DE VERDAD antes de parchear.** Se parchearon
primero las cuatro tools del agente, cuando ya se sabía —por las pruebas de
2C.2— que el camino real de registro de beneficiarios es
`Registrar beneficiario auto`, la ruta determinista. En todas las pruebas del
día corrió esa y ninguna vez las tools.

Copia previa: `ROLLBACK-v2-antes-2D.json`.

### ✅ 2D — rehecho y desplegado el mismo día (migración `044`)

Al segundo intento, con las tres cosas que faltaron:

1. `to_jsonb($N::text)` — **el cast no es opcional**
2. **`PREPARE` de las cinco queries completas**, sin excepciones
3. Probado contra la ruta que corre de verdad (`Registrar beneficiario auto`)

Verificado end-to-end: fila en el log con su `execution_id`, argumentos
correctos, y deal + operación + beneficiario encadenados. 0 divergencias.

**Qué protege la clave de idempotencia, y qué no** — importa no confundirse:

- ✅ **Sí** evita que el agente ejecute dos veces la misma herramienta con los
  mismos argumentos **dentro del mismo turno**.
- ❌ **No** protege del reintento de un lote: un reintento es una **ejecución
  nueva** de n8n, con `execution_id` distinto, luego clave distinta.

Cubrir también los reintentos exige anclar la clave a algo estable entre ellos
—el `whatsapp_message_id` que originó el lote— en vez de al `execution_id`. Es
un rediseño, no un ajuste, y no se hizo: las cuatro tools con guarda por
contenido ya son idempotentes de hecho.

**Limitación conocida:** en el camino de creación, `operation_id` queda `NULL`
en el log, porque la operación aún no existe cuando corre la tool — la crea el
trigger un instante después, junto con el deal.

---

### Decisiones que hay que tomar antes de arrancar

1. ~~**¿Un cliente abre de verdad dos remesas a la vez?**~~ ✅ **Contestada por
   Humberto el 8-ago: SÍ pasa.** No es lo común, pero ha visto clientes abrir
   dos —por ejemplo un depósito para recibir Zelle y otro para recibir CUP—.
   Eso **justifica la Fase 2**: deja de ser complejidad especulativa y pasa a
   ser el arreglo de un fallo real.
2. **Cómo se inyecta el `operation_id`** en las herramientas. Propuesta: por
   expresión del workflow, no por el modelo, para no tocar el prompt.
3. **¿`depositos_mmg` se absorbe o se enlaza?** Recomiendo enlazar: 332 filas y
   un flujo de ingesta propio que funciona. Además ahora tiene lógica propia
   encima (plan B y antigüedad), y absorberla obligaría a rehacerla.
4. **¿Migrar el historial?** Con 8 deals se puede reconstruir parseando las
   notas una vez, o empezar limpio. Lo segundo es más barato y más honesto.

---

## 🟡 WaCRM

### 6. ~~Desplegar el artefacto construido en CI~~ — ✅ **HECHO (adelantado por emergencia, 8-ago 02:36)**

> **Cómo pasó:** el build del fix de chats **en el VPS** llevó la máquina al
> thrashing (1 GB de RAM + `output: standalone`): 21 min sin terminar, app y
> ssh sin responder, reinicio desde la consola de Oracle. El build
> interrumpido dejó `.next` sin `BUILD_ID` → bucle de reinicios. Como la copia
> de seguridad **no incluía `.next`** y recompilar era inviable, la única
> salida fue adelantar el pipeline nuevo. Funcionó.
>
> **Verificado por mí con tráfico real:** 22 mensajes entrantes → 22 eventos
> en `session_events`, 2,5 s de latencia, 0 pendientes, 0 fallos. En la
> ventana del incidente solo entraron 2 mensajes, ambos del número de pruebas
> y respondidos en 21 s. **Cero impacto en clientes.**
>
> **Dos cosas que salieron de rebote:**
> - El wrapper de la clave del runner tenía escapes dobles del heredoc y
>   rompía el `rsync`. Habría fallado el domingo con todos mirando.
> - La regla del firewall para el 443 no estaba persistida. Llevaba meses
>   así; el primer reinicio la habría borrado en cualquier momento.
>
> **Lecciones:** si alguna vez se vuelve a compilar en el VPS, el `.next` va
> en la copia. Y no volver a compilar ahí ni de emergencia — el rollback real
> hoy es re-disparar el workflow.
>
> **Disparo controlado — ✅ hecho el 8-ago 03:05.** Run `31236145520`, los seis
> pasos en verde incluido el healthcheck, que nunca había llegado a pasar. Sin
> una sola diferencia contra la línea base. **Punto 7 cerrado con un WhatsApp
> real:** entró a las 03:09:05, llegó a `session_events` en 4,12 s, el lote se
> cerró y el agente respondió a las 03:09:25. El `--exclude` protegió el
> `.env.local` del `--delete`, verificado por timestamp.

### 6bis. ~~Orden de los chats fijados~~ — ✅ **ARREGLADO (8-ago)**

> Los fijados se descolocaban al llegar mensajes. No era el SQL: la lista se
> pintaba en el orden del array y el array se mutaba en vivo con
> `[nuevo, ...prev]` sin reordenar. Arreglado ordenando en el `useMemo` de
> `filtered`, un solo punto imposible de saltarse. Las 5 comprobaciones en el
> navegador, pasadas — incluida la del chat oculto que reaparece, que nadie
> había probado nunca.


> Especificación y decisiones en la [issue #1](https://github.com/hmartinezenzona-rgb/wacrm/issues/1).

**Cómo funciona hoy** (verificado leyendo `deploy.yml` el 8-ago, no de memoria):

Workflow `Deploy`, disparo manual (`workflow_dispatch`). Compila en el runner
con los `NEXT_PUBLIC_*` reales, empaqueta el `standalone`, `rsync -az --delete`
al VPS y `pm2-restart-wacrm`. **El VPS ya no compila nada.**

Tres detalles que conviene no volver a tocar:

- `cp -a .next/standalone/.` — con **punto**, no con asterisco. El glob se salta
  los ficheros ocultos y deja fuera `.next/standalone/.next/`: el servidor
  arranca y se cae en la primera página. Ya estuvo a punto de pasar.
- `cp -r public deploy/public` — los ficheros estáticos sí viajan.
- `--exclude=.env.local` protege la configuración del VPS del `--delete`.

**Lo que sigue sin garantizarse:** el despliegue **no comprueba que el CI esté
en verde**. Corre su propio `npm run build`, que sí type-checkea, pero el lint y
los tests solo se ejecutan en el CI. Se puede desplegar un commit con los tests
en rojo si nadie mira.

### 7. Otros

- **39 warnings de `react-hooks/exhaustive-deps`.** Cosméticos en apariencia,
  pero pueden esconder closures obsoletos
- ~~`ignoreBuildErrors: true` se queda~~ ✅ **Ya no existe.** Comprobado el 8-ago:
  no aparece en `next.config.ts` ni en ningún sitio del repo. Al mudar la
  compilación al CI dejó de hacer falta, porque el runner aguanta lo que el VPS
  de 1 GB no aguantaba. **Consecuencia buena:** un error de tipos ahora aborta
  el despliegue antes de tocar el VPS
- **Flujo de PRs**: acordado con Hermes pero **sin estrenar**. Para lo que toque
  dinero, datos o el Cerebro: rama + PR y lo reviso. Para ajustes visuales, su
  flujo directo
- ~~Mi acceso a GitHub es de solo lectura~~ ✅ **Resuelto el 7-ago**: PAT clásico
  con scope `repo` en `~/.github-token`, verificado creando y borrando una rama.
  Ya puedo abrir issues y comentar PRs en línea. **Ese token también quedó
  escrito en una conversación** — mismo criterio que los demás: rotar cuando se
  pueda

### 8. Transición del HMAC — último paso

**No quitar todavía el `?secret=`** de la URL de WaCRM. Es lo único que mantiene
utilizable el Cerebro v1 como rollback. Se retira cuando v2 lleve varios días
estable y se decida jubilar el v1.

---

## 🟠 Lo más frágil de todo el montaje

### 9. No hay entorno de pruebas

Todo va contra producción: el VPS y la base. No lo arregla ni el CI ni los PRs
—esos detectan errores antes, no evitan que un despliegue malo tumbe el
servicio—. Es la conversación pendiente más importante y la única que cambia
la naturaleza del riesgo en vez de reducirlo un poco.

---

## 🔵 Detalles menores

- **Un tono de aviso más bonito.** El actual cumple y se oye, pero es un pitido
  sintético. Cuando alguien tenga un rato, un sonido más agradable — va a sonar
  varias veces al día durante meses. Fichero: `public/sounds/incidencia.mp3` en
  WaCRM. **Lo único que no se puede olvidar es medir el pico antes de
  desplegarlo**: los dos intentos anteriores salieron a -29 dBFS y eran
  inaudibles, y eso escuchándolo se confunde con "suena corto".
- **El fichero del tono conserva el nombre** entre versiones, y `/sounds/*` cae
  en la regla de caché general (`s-maxage=300, stale-while-revalidate=86400`).
  Renombrarlo a `incidencia-v2.mp3` al cambiarlo evitaría que el borde sirva el
  anterior durante horas.

---

## 🔵 Deuda de datos detectada al medir

Ninguna estaba en ningún spec; salieron al revisar la base. **Cifras medidas de
nuevo el 8-ago**, porque las anteriores se habían quedado viejas.

| | Hallazgo |
|---|---|
| 10 | **12 deals en "Entregada" siguen con `status='open'`**, de 14 en el pipeline. Nadie los cierra. Hoy no rompe nada porque las consultas filtran por etapa, pero significa que `status` **no es fiable** como señal |
| 11 | **2 deals entregados no tienen beneficiario registrado.** Se entregó dinero y el sistema no sabe a quién. Se resolvió por fuera |
| 12 | ~~86 de 332 depósitos MMG sin consumir~~ ✅ **Resuelto el 8-ago.** Eran **76 de antes del arranque** (la ingesta arrastró el buzón desde abril; el sistema no existe hasta el 5-ago) y **11 pendientes de verdad**. Los 76 llevan ahora `descartado_en` con su motivo — marca honesta, no marcados como "consumidos", para no repetir el error de la deuda 15. Ver `09-descartar-depositos-previos.sql` |
| 15 | **228 depósitos figuran como consumidos sin ningún envío asociado**, desde el 4 de julio. Los dejó así el flujo viejo, que marcaba el depósito como usado sin registrar a qué operación pertenecía. **De 334 depósitos, solo 12 tienen el rastro completo** hasta su envío, y son todos del 5-ago en adelante. No afecta a nadie hoy, pero ese es el límite si alguna vez hay que auditar de dónde salió un pago antiguo |
| 16 | ~~Dos depósitos de 367.500 GYD sin identificar~~ ✅ **Cerrado sin acción, y con un cambio de criterio.** No se pueden distinguir: los 334 depósitos llevan el mismo asunto (`CASH_IN_TO_AGENT_OK_RECEIVER`) y la misma frase *"to your wallet"*, venga de un cliente o del propio Osmany recargando saldo. Y el importe tampoco sirve — el mayor de la tabla, 925.000 GYD, sí fue una remesa real. **Criterio de Humberto, y es el correcto: un depósito solo cuenta cuando alguien lo reclama con su comprobante; hasta entonces solo existe.** Así que no hay nada que marcar ni que perseguir |
| 13 | **Un deal desapareció** el 7 de agosto entre las 10:36 y las 10:40 UTC, con su hash de comprobante. Ningún workflow automático borra deals — lo verifiqué. Probablemente lo borró un operador. Si no fue así, hay algo borrando deals y eso es más grave que cualquier otra cosa de esta lista |
| 14 | **`registrar_beneficiario_zelle` puede contaminar.** Coge el deal abierto más reciente y escribe "BENEFICIARIO ZELLE ACTUALIZADO — reemplaza al anterior", lo que puede borrar el destino de una operación ya completada. Una guarda ingenua rompería las correcciones legítimas. Se agrava ahora que sabemos que **sí** hay clientes con dos remesas a la vez |

---

## Vigilancia — lo primero al abrir el lunes

Añadido el 9-ago. **Todo lo desplegado ese día se probó en domingo, sin
clientes.** Estas cinco consultas dicen en un minuto si algo hace ruido:

```sql
-- 1. LA MAS IMPORTANTE. Debe dar 0 filas siempre.
--    Si sale algo, un trigger de la Fase 2 esta fallando en silencio.
SELECT * FROM cerebro_conciliacion_operaciones;

-- 2. Salud de siempre
SELECT count(*) FROM session_events WHERE processing_status <> 'completed';

-- 3. NUEVO: alguna conversacion con DOS operaciones vivas.
--    Si sale, el sistema la esta derivando a un humano en vez de adivinar.
--    Seria la primera vez que ese caso ocurre de verdad.
SELECT conversation_id, count(*) FROM remittance_operations
 WHERE status NOT IN ('completed','cancelled')
 GROUP BY 1 HAVING count(*) > 1;

-- 4. NUEVO: el outbox registra lo que se envia (fase 1, en sombra).
--    Debe haber UNA fila por respuesta enviada, ni mas ni menos.
--    OJO: todas quedan en 'pending' porque aun no hay enviador. Es normal.
SELECT * FROM cerebro_outbox_salud;
--    Y ninguna debe decir "encolado sin ancla de wamid":
SELECT count(*) FROM message_outbox WHERE last_error LIKE '%sin ancla%';

-- 5. NUEVO: el vigilante de promociones sigue vivo (corre cada 12 h)
SELECT valor::timestamptz AS ultima_revision,
       now() - valor::timestamptz AS hace_cuanto
  FROM cerebro_config WHERE clave='promo_etecsa_ultima_revision';
```

**Y una que no es SQL:** que ninguna conversación real acabe derivada a un
humano sin motivo. Si el equipo ve derivaciones raras el lunes, el sospechoso
es el resolutor de operaciones (tramo 2C.2).

---

## Vigilancia diaria de siempre

`05-vigilancia-diaria.sql` — cinco consultas que dan el estado del sistema en
30 segundos. Lo que más conviene mirar a diario: lotes atascados, errores
permanentes y comprobantes sin deal.

**Dos añadidas el 8-ago:**

```sql
-- Depositos dados por buenos sin que la referencia cuadrara exacta.
-- HAY QUE CONFIRMARLOS A OJO contra el comprobante del chat.
SELECT id, value, updated_at, notes FROM deals
 WHERE notes LIKE '%COINCIDENCIA APROXIMADA%' ORDER BY updated_at DESC;

-- Depositos frenados por antiguos: existen y cuadran, pero son viejos.
SELECT id, value, updated_at, notes FROM deals
 WHERE notes LIKE '%DEPOSITO ANTIGUO%' ORDER BY updated_at DESC;
```

El cron `rNN0LdHGTYUDOTfB` ya avisa en el CRM de los mensajes rechazados, así
que eso no hace falta mirarlo a mano.

## Rollback del Cerebro

Tres pasos, 30 segundos, sin Hermes:

1. Desactivar Cerebro v2 (`T3v07IQqtMs6AKJ4`)
2. Activar Cerebro v1 (`NgnTPBVzO1m0NPYz`)
3. `UPDATE session_events SET procesado=false WHERE processing_status IN ('processing','retry_wait');`

Respaldos en `ROLLBACK-v1.json`, `ROLLBACK-v2.json`,
`ROLLBACK-v2-antes-2B.json`, `ROLLBACK-v2-antes-retryOnFail.json`,
`ROLLBACK-notify.json`, `ROLLBACK-v2-antes-cruce-aproximado.json`,
`ROLLBACK-notificador-antes-cruce-aprox.json`.

### Revertir solo lo del 8-ago por la tarde

Cada pieza se apaga por separado, sin tocar las demás:

| Qué | Cómo |
|---|---|
| Cruce con plan B y antigüedad | Devolver al nodo `Cruzar deposito con MMG` su consulta de `ROLLBACK-v2-antes-cruce-aproximado.json` |
| Aviso de incidencia en el CRM | `DROP TRIGGER trg_notify_deal_incidencia ON deals;` |
| Vigilante de mensajes rechazados | Desactivar el workflow `rNN0LdHGTYUDOTfB` en n8n |

Las funciones pueden quedarse: sin nadie que las llame, no hacen nada.
