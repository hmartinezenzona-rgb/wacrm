# Pendientes — Remesas Ya

Estado al **14 de agosto de 2026, 00:45 de Guyana**.
Ordenado por lo que más duele si no se toca.

> ## LO PRIMERO AL ABRIR HOY
>
> Se desplegaron **once cosas** entre la tarde del 13 y la madrugada del 14, y
> **solo una está probada con un cliente real** (la pausa del bot). Lo demás
> pasó su banco, que demuestra que no se rompió nada — no que funcione. Lo que
> hay que mirar con la jornada en marcha:
>
> | Qué mirar | Cuándo se ve |
> |---|---|
> | El nombre de un contacto ya no se revierte | renombrar uno y que esa persona escriba |
> | El aviso de «próximo a cerrar» | **entre las 16:30 y las 17:00** |
> | El mínimo de Zelle (13.000) | que alguien pregunte el mínimo |
> | El MLC: se deriva y llega el aviso | que alguien pregunte por MLC |
> | Zelle normalizado a 10 dígitos | con el primer beneficiario Zelle |
> | `incident` en el resolver | un envío en Incidencia que reciba beneficiario |
> | El bot cierra el agradecimiento | un «gracias» en un chat derivado |
> | Referencia imposible → Incidencia | una captura que la visión lea mal |
>
> **Y una que puede tener a un cliente esperando:** diez depósitos sin dueño —
> los ocho del sábado más los dos del 13-ago (5.000 y 10.000 GYD).

> ## Lo del 13-ago y su madrugada, en seis líneas
>
> 1. **El día salió bien en dinero: 8 envíos, 447.800 GYD, 0 perdidos.** La
>    ingesta de MMG no se cayó ni un minuto y cruzó 7 de 9 depósitos en menos
>    de 90 s. El libro cierra cuadrado: 8 depósitos cruzados = 447.800 GYD.
> 2. **Lo que falló fue el RUIDO y lo INVISIBLE**, no el dinero. De 58 avisos,
>    **33 eran falsos**: 24 por un «Gracia» y 9 por un depósito fantasma.
> 3. **Atacado por los dos lados.** El ruido: raíz `gra[cs]ias?`, repetición
>    según el estado del cliente, y **el bot cerrando el agradecimiento**, que
>    es la idea de Osmany y quita la causa en vez de filtrarla. El fantasma:
>    una referencia que no puede ser un TransID ya no se registra.
> 4. **MMG dejó de mandar un correo** — primer `sin_correo` real, comprobado
>    leyendo el buzón. El libro se cuadró a mano.
> 5. **Dos sustos que enseñaron más que los aciertos:** una corrección en masa
>    movió `updated_at` y resucitó 14 deals viejos en el tablero; y el corte a
>    medianoche vació la columna «Entregada» a las 00:13 y **pareció que se
>    habían borrado los envíos**. Nada se perdió en ninguno de los dos, pero un
>    tablero que parece haber perdido datos es un tablero roto.
> 6. **Herramientas nuevas:** `pruebas/banco-sql.py` (los nodos Postgres ya
>    tienen red, con `--workflow` y `--revertir`) y `pruebas/traer-sql.py`
>    (parchear funciones de la base sin retecleatlas).

> ## Lo del 13-ago, en cinco líneas
>
> 1. **El día salió bien en dinero: 8 envíos reales, 447.800 GYD, 0 perdidos.**
>    321.200 entregados y 126.600 esperando transferencia al cierre. La ingesta
>    de MMG no se cayó ni un minuto y cruzó 7 de 9 depósitos en menos de 90 s.
> 2. **Lo que falló no fue el dinero, fue el RUIDO y lo INVISIBLE.** De 58 avisos
>    del día, **24 (41%) eran un «Gracia»** de una clienta ya atendida, y otros 9
>    eran un depósito fantasma que el bot se inventó de una captura.
> 3. **Tres deals estuvieron ocultos del tablero a la vez** por `status='lost'`,
>    entre ellos uno con 39.000 GYD de un cliente esperando. El botón «Marcar
>    como perdida» los esconde y el de reabrir vive dentro de la ficha
>    escondida. Ver el 🔴 correspondiente.
> 4. **MMG dejó de mandar un correo.** Primer `sin_correo` real: el depósito de
>    39.000 de Yari existe (comprobante bueno, TransID coherente) pero su aviso
>    NO está en el buzón, ni en spam ni en papelera. Comprobado leyendo el buzón,
>    no deducido. El libro de depósitos cuadra corto por esos 39.000.
> 5. **Desplegado hoy:** `incident` en `cerebro_resolver_operacion` (los seis
>    nodos), para que un envío en Incidencia deje de partirse en dos. Con banco
>    nuevo: `pruebas/banco-sql.py`, el hermano de `banco.py` para nodos Postgres.

> ## Lo de la madrugada del 12-ago, en cuatro líneas
>
> 1. **La ráfaga de varios comprobantes YA SE SUMA** y se cruza todo-o-nada.
>    El caso de Melih está resuelto. Ver `26-…md`.
> 2. **El saldo del envío está ENCENDIDO** para la vía Zelle/USD: el cliente dice
>    cuánto va a mandar, `calcular_usd` lo apunta al cotizar, y un depósito corto
>    ya no se da por bueno — se le dice cuánto falta y el envío espera.
> 3. **Con su red puesta:** `Vigilante - envios incompletos` (`O1TqpAJXgRfKCiW6`),
>    cada 10 min, avisa en el CRM si un envío lleva 4 h sin completar.
> 4. **El DSML está entendido y acotado, pero sin arreglo de fondo.** Es del
>    proveedor y ninguna palanca nuestra lo cambia — se midieron siete. La tasa
>    va de 0% a 100% en minutos, y en racha mala reintentar no salva. Ahora hay
>    un banco que lo reproduce a voluntad. Ver `27-el-dsml-entendido.md`.

> **Lo primero al abrir mañana, antes de tocar nada:** cuatro cosas se
> desplegaron con el negocio ya cerrado y **no han visto tráfico real de
> clientes**. Hay que mirarlas con la jornada en marcha:
>
> | Qué | Cómo se comprueba |
> |---|---|
> | **Rastro de webhooks** | `SELECT count(*), count(*) FILTER (WHERE NOT procesado) FROM whatsapp_webhook_log;` — debe llenarse y quedar casi todo `procesado` |
> | **Migración 062** | que no vuelvan avisos `chat_atascado` por despedidas |
> | **Normalizador (hueco 3)** | que las respuestas cortas con pregunta salgan en dos párrafos |
> | **Orden de la tubería** | que no salga ningún `SKIP` ni razonamiento al cliente |
>
> La lección del día, repetida tres veces: **hasta que algo no produce un efecto
> real, no está probado.** Dos vigilantes y una tabla pasaron todas las pruebas
> y estaban rotos (`notifications_type_check`, `permission denied`).

> ## Lo que queda abierto, en una pantalla
>
> | | Qué | Depende de |
> |---|---|---|
> | ✅ | ~~**El nombre de un contacto se revierte solo**~~ — **CERRADO el 14-ago 00:45 UTC, dado por bueno por Humberto.** Desplegado (`4f731ee3`) y **probado con mensajes reales**: renombró dos contactos y le escribieron **18 y 12 segundos después**; los nombres aguantaron y —la señal que más pesa— **`updated_at` NO se movió** (el `UPDATE` del webhook lo escribe explícitamente, así que no llegó a correr). Quedan dos huecos conocidos y aceptados: **(a)** no se pudo leer el nombre que traía el perfil, porque el rastro de webhooks guarda solo el objeto del mensaje y no el bloque `contacts[].profile` del sobre — arreglarlo son dos líneas y haría trivial esta comprobación; **(b)** el **control al revés sigue sin verse**: un contacto con `name_source='whatsapp'` recibiendo nombre de perfil (el `5358741800` no vale, se creó, no se actualizó). Y el **test automático no existe** |
> | 🟢 | **Un deal viejo resucitaba en la columna al editarlo — CERRADO DE RAÍZ** (migración **083** + commit `d0da73ea`, CI en verde; **falta que Humberto dispare el Deploy**). Lo destapó Osmany: entró a WaCRM y vio remesas del 6 al 12 de agosto en «Entregada». **Causa: mía.** Al normalizar las cuentas Zelle toqué las notas de 14 deals, y el trigger `set_updated_at` mueve `updated_at` en CUALQUIER edición — que era justo el campo por el que filtraba la columna. Reparado al momento devolviéndoles su fecha desde `remittance_operations.completed_at` (con el trigger desactivado dentro de un bloque `DO` atómico). Y cerrado de raíz: **`deals.entregado_en`**, que solo escribe `cerebro_cerrar_deal_entregado` al ENTRAR en la etapa y borra al salir, y el tablero ya filtra por él. Los 60 ganados sellados, 0 sin sello, y el filtro nuevo da hoy lo mismo que el viejo (7). Probado en bloque revertido: editar notas de un entregado del 6-ago deja el sello **intacto** aunque `updated_at` se mueva; sacarlo de Entregada lo borra; devolverlo lo vuelve a sellar | lección anotada en memoria: **respaldar la fila entera**, no los campos que crees que cambias |
> | 🟢 | **EL CORTE A MEDIANOCHE ASUSTÓ, Y CON RAZÓN — corregido y desplegado** (14-ago 00:13 de Guyana). Osmany entró al CRM y la columna «Entregada» estaba vacía: *«borraste los deals de entregados»*. **No se borró nada** —65 deals, 60 entregados con su sello, 2.178.110 GYD intactos, comprobado— era el filtro: el día natural acababa de cambiar. Pero la elección del corte era mía y estaba mal pensada para un negocio que abre a las 9:00: dejaba la columna vacía toda la madrugada **y toda la mañana** hasta la primera entrega, que es justo cuando se abre el CRM a repasar lo de ayer. **Corregido** (commit `e6bb8dfa`, CI en verde, **falta el Deploy**): el corte pasa a la **hora de abrir**, las 9:00 de Guyana. Entre las 00:00 y las 9:00 no se entrega nada, así que hasta que el negocio abre se sigue viendo el día anterior y la columna cambia justo al empezar la jornada. Probado con node en los cinco momentos que importan; con el corte nuevo, a las 00:20 se ven las 7 entregas del 13-ago | **la lección:** un tablero que *parece* haber perdido los datos es un tablero roto, aunque los datos estén. Al elegir una ventana, pensar en qué se ve a las 3 de la mañana y a las 9 menos cuarto |
> | 🟢 | **La columna «Entregada» se llenaba — RESUELTO SIN BORRAR NADA** (14-ago, commit final **`b28f070c`**, CI en verde, **falta que Humberto dispare el Deploy**). La columna muestra los abiertos **+ lo entregado HOY**, cortando por **medianoche de Guyana** (UTC-4, sin horario de verano) — no por ventana móvil de 24 h, que arrastraba la tarde de ayer hasta la misma hora del día siguiente. Como entre las 00:00 y las 9:00 no se entrega nada, en la práctica se ve «lo entregado desde que abrimos», pero el corte es la medianoche. Pedía borrar los deals completados a diario. **No hace falta y sale caro:** el histórico YA no depende de `deals` — `cerebro_historial_operaciones` y `cerebro_volumen_diario` se construyen sobre `remittance_operations` + `contacts` + `remittance_beneficiaries`, y el importe cae a `quoted_source_amount` con **0 descuadres sobre 62 operaciones** (2.212.677 GYD idéntico con y sin deals). Probado en vivo con dos operaciones cuyo deal ya estaba borrado: salen enteras en el resumen. **Lo que sí se perdería al borrar:** `depositos_mmg.deal_id` es `ON DELETE SET NULL` y hay **47 depósitos atados a un deal entregado** — se iría qué depósito pagó qué remesa, más el texto de las notas. Así que se acortó la ventana del tablero de 7 días a 24 h: la columna pasa de **59 tarjetas a 7** y los 4 abiertos no se tocan | si aun así quieres borrarlos de verdad, antes hay que preservar el enlace depósito↔remesa (una columna `operation_id` en `depositos_mmg`) |
> | 🟢 | **Pausar el bot en una conversación — DESPLEGADO el 14-ago 02:5x UTC**, sin ver tráfico real todavía. **El botón NO se veía, y me equivoqué al decir que sí.** Lo corrigió Osmany: el `AiThreadBanner` existe en el código pero hace `if (!autoReplyOn) return null`, y esa bandera es la **IA propia de WaCRM**, apagada aquí porque el bot es el Cerebro en n8n. Así que hubo que **crear el control**: va en la **barra lateral derecha, debajo de Notas** (commits `ab94ae9c`, `289c53fe`, `3888b320`, CI en verde, **falta el Deploy**), reusa `POST /api/ai/autoreply/[id]` **omitiendo `assign_to_me`** —pausar no debe apropiarse del chat— y al reanudar el endpoint libera cualquier asignación, que hace falta porque el Cerebro también se calla con el chat asignado. La otra mitad, la del Cerebro, ya está activa: **no miraba `conversations.ai_autoreply_disabled`**: se callaba solo porque ese mismo botón ASIGNA el chat. Y eso no bastaba — las asignaciones manuales **caducan solas** (CTE `caducar`), así que pasados los minutos sin actividad humana el chat se liberaba y **el bot volvía a hablar con la pausa todavía puesta**. Ahora `Contexto conversacion` sirve `bot_pausado` y el `Decisor` corta antes que nada, incluso antes de la asignación. Banco: batería 2/2 (con pausa no sale NADA; sin pausa sale el contexto de siempre, que es el control) y matriz de 6 combinaciones con **0 cambios**. Rollbacks: `ROLLBACK-v2-antes-bot-pausado.json` y `-antes-decisor.json` | **PROBADO EN PRODUCCIÓN el 14-ago 03:04 UTC** (23:04 de Guyana) por Osmany, y por el motivo correcto — ejecución `37336`: `Contexto conversacion` devolvió `bot_pausado: True` con **`asignado: False`, `humano_reciente: False` y `oculta: False`**, o sea que ninguno de los tres silencios viejos estaba activo, y el `Decisor` cortó con `ruta: silencio, motivo: "bot pausado a mano en esta conversacion"`. Cadena completa demostrada: botón → endpoint → columna → SQL → Decisor. La pausa **NO caduca** a propósito — dura hasta que se pulse «reanudar». La red contra olvidarla puesta es el vigilante de chats atascados, que avisa igual |
> | 🟢 | **Aviso de «próximo a cerrar» — DESPLEGADO el 14-ago 01:1x UTC, sin ver tráfico real todavía.** Umbral en **30 min** (`cierre_aviso_minutos` en `cerebro_config`; `0` lo apaga, se mueve sin desplegar). Tres piezas: **(1)** `Contexto conversacion` sirve el booleano `por_cerrar`, calculado en SQL con el reloj de la BASE — validado con `banco-sql.py` y **ejecutado contra una conversación real**; límites comprobados (16:29 no, 16:30 sí, 16:59 sí, 17:00 no). **(2)** el `Decisor` empuja la nota `PROXIMO A CERRAR` — `banco.py --perfil contexto`, batería 4/4 y **0 regresiones**: de 6 combinaciones cambian solo las 3 de `por_cerrar`. **(3)** el prompt ajusta la promesa de la transferencia, probado con node en sus 4 ramas incluida la de contexto inalcanzable. Rollbacks: `ROLLBACK-v2-antes-por-cerrar.json`, `-antes-decisor.json`, `-antes-prompt-por-cerrar.json` | **falta verlo entre las 16:30 y las 17:00 de un día laborable** — es la única prueba que vale. Y decidir si 30 min bastan: los datos decían que la caída empieza a las 15:00 |
> | ⛔ | **Borrar mensajes del bot o de un admin — DESCARTADO el 14-ago**, no volver a proponerlo. La idea era que **el cliente** no viera un mensaje incoherente, y eso **no se puede**: la Cloud API de Meta no tiene endpoint para revocar lo ya enviado (su webhook `revoke` es al revés, avisa cuando el cliente borra algo suyo). Sin eso solo se limpiaba el CRM, y Humberto lo canceló entero. Migración 081 aplicada y **revertida por la 082** (su índice parcial indexaba `messages` entera). Lo que sí quedó, medido y que vale más que la función: **la memoria del modelo es `cerebro_memoria`, no `messages`**, sin enlace entre ambas — casar por texto acierta 526 de 702 (75%), 38 ambiguos y 158 fallan porque el normalizador reescribe lo enviado. Y de los 6 nodos que leen `messages`, solo `Ultima cotizacion` mira el contenido | cerrado |
> | 🟢 | **El bot cotizaba MLC como si fuera dólar — DESPLEGADO el 14-ago 03:2x UTC**, sin ver tráfico real todavía. **El MLC no existe en el sistema**: no está en `cerebro_servicios` ni tiene tasa en `tasas`, así que preguntado por él el modelo caía en la del USD. Dos veces con Yoandy cruz (5926597626): *«El MLC se deposita en la tarjeta en dolares, el calculo es el mismo: para 13 USD necesita depositar 3,380 GYD»* (12-ago) y *«Para los 40 MLC necesita depositar 10,400 GYD»* (13-ago), las dos a **260 GYD por unidad**. Decisión de Osmany: esa tasa fluctúa, lo atiende una persona — **no se le pone tasa al bot, se le quita el tema**. Migración **084**: `cerebro_pide_mlc` (la detección, en UN solo sitio) y `cerebro_avisar_mlc` (aviso en la campana del CRM, uno por admin, throttle de 6 h). Cableado en tres nodos: `Control de abuso` avisa **en SQL antes del modelo** —así el admin se entera aunque el modelo desobedezca—, `Contexto conversacion` sirve `pide_mlc` y el `Decisor` mete la prohibición **como última nota**, que es la que gana en una colisión. Banco 2/2 y matriz de 6 combinaciones con 0 cambios; detección probada contra 10 frases (caza «MLC?» y «Mlc», no se confunde con «el amlcen»); aviso probado entero en bloque revertido: 3 notificaciones y la segunda llamada bloqueada por el throttle **Y SE DERIVA EL CHAT, no solo se avisa** (segunda vuelta, a petición de Osmany: *«la tasa del MLC varía mucho y por eso se debe derivar a un admin»*). Avisar no bastaba: sin derivar, el bot seguía llevando la conversación y en el mensaje siguiente podía volver a cotizar. El CTE `derivar_mlc` de `Contexto conversacion` lo pasa al perfil de derivaciones del bot, que **no caduca**. Y el orden juega a favor: como el `SELECT` lee la instantánea anterior al `UPDATE`, **este turno el bot todavía habla** —para decir que le atiende un compañero— y a partir del siguiente ya se calla solo. Probado en bloque revertido: sin asignar → asignado al perfil de derivaciones | **falta el primer cliente real que pregunte por MLC.** Y queda una decisión de fondo: si algún día se quiere cotizar MLC, hace falta una tasa que alguien mantenga, como la del USD |
> | 🟢 | **El bot no sabía el mínimo de Zelle — DESPLEGADO el 14-ago 03:4x UTC**, sin tráfico real todavía. El único mínimo que conocía era el de las recargas, así que ante un «¿cuánto es lo mínimo?» o ante alguien pidiendo menos de la cuenta se lo inventaba o lo omitía. Ahora `cerebro_config.zelle_minimo_gyd` = **13.000** (Osmany) y `Ultima cotizacion` sirve la frase ya montada: *«MINIMO PARA ZELLE / envios en USD: 13,000 GYD (50 USD). Por debajo de eso NO se hace el envio…»*. **El equivalente en USD lo calcula el SQL con la tasa viva**, así que no se queda viejo. El `Decisor` la inyecta **solo si el mensaje viene a cuento** (`zelle|usd|dolar|minimo`), igual que las recargas, para no engordar el contexto. Banco 2/2 —aparece al preguntar el mínimo, NO aparece en una remesa en CUP— y matriz de 6 con 0 cambios | se cambia con un `UPDATE` en `cerebro_config`, sin desplegar. Ojo: el servicio de México documenta el mismo número por su cuenta en `cerebro_servicios`; si cambia uno hay que mirar el otro |
> | 🟢 | **El ruido de los avisos — ATACADO el 14-ago, migración 085.** De los 58 avisos del 13-ago, 24 eran `chat_atascado`, y **los 11 de toda la historia son la misma clienta**: 2 legítimos (con operación abierta) y 9 de ruido, un «Gracia» repetido cada hora durante 8 horas. **Dos capas, y ninguna puede callar el PRIMER aviso de nadie.** (1) La lista de palabras pasa a la **raíz** `gra[cs]ias?` — Osmany tenía razón en que añadir la `s` era el juego del topo, pero la raíz cubre gracia/gracias/grasia/grasias sin dejar de ser estricta. (2) El **intervalo de repetición mira el estado**: 60 min con operación abierta, **360 sin ella** (`chat_atascado_repetir_sin_operacion_min`). Esto NO decide a quién se avisa, solo cada cuánto se insiste, así que el punto ciego que daba miedo —cliente nuevo, cero operaciones, ignorado— sigue generando su aviso. **Aplicada sin reescribir la función**: la migración lee su propia definición viva, hace reemplazos exactos y aborta si un ancla no aparece (hacía falta, porque la función viva **no coincidía** con el fichero 062: 4.704 caracteres normalizados frente a 4.191). Probado 11/11 contra frases reales, y demostrado el antes/después sobre el caso de Inelvis: `callaba_antes = false`, `calla_ahora = true`. El vigilante ahora devuelve **0 chats atascados** **Y LA IDEA BUENA, CONSTRUIDA TAMBIÉN** (migración 086 + `Contexto conversacion` + `Decisor`): **el bot cierra el agradecimiento**. En un chat que lleva una persona el bot callaba SIEMPRE; ahora, y solo si la ráfaga entera es cortesía pura, devuelve la cortesía en una línea y cierra. Eso quita la causa en vez de filtrar el síntoma: si nadie deja el mensaje sin responder, no hay chat atascado, en cualquier redacción y cualquier idioma. **Lo contesta el modelo, no un texto fijo** — decisión de Osmany, y es más rápido: no hay que recablear el workflow y además responde en el idioma del cliente (hay clientes en inglés). El riesgo de que diga de más está acotado por `cerebro_es_cortesia`, que exige sin pregunta, sin cifras y sin nada pendiente: el modelo no tiene números que equivocar. Va **después** de la ventana de silencio, así que si una persona acaba de escribir manda ella, y **corta antes de armar contexto**: en un chat ajeno el modelo no recibe depósitos, beneficiarios ni tools. La regla vive en **una sola función** que usan el vigilante y el bot, para que no puedan discrepar. Banco: 3/3 en sus tres caras (asignado+cortesía → contesta; asignado+no cortesía → callado; humano reciente → callado aunque sea cortesía) y matriz de 6 con 0 cambios | **falta verlo con tráfico**: que un cliente dé las gracias en un chat derivado y el bot cierre con una línea |
> | 🟢 | **El bot se inventaba un depósito de una captura — ATACADO el 14-ago, migración 087.** Al abrir la imagen resultó **peor de lo que parecía**: no era «una captura cualquiera», era una **captura de OTRA conversación de WhatsApp que dentro tenía la FOTO de un comprobante** — un recibo dentro de una foto dentro de una captura. Y la visión **se inventó las dos cifras**: registró 5.000 GYD con ref `10319372234891` cuando el comprobante de la imagen decía **26.000 y 10395727229361**. **La señal que sí sirve:** el TransID de MMG es un contador que **solo crece**. Los 724 recibidos van de `10378363543358` (31-dic-2025) a `21396936623433`. Un número por debajo del suelo histórico **no puede existir**. Medido: los **724 reales pasan**, el inventado **no**, y el de la foto **sí**. No se fija la longitud a propósito — el propio proyecto tiene escrito que el TransID pasó de 10 a 14 dígitos, así que se compara por VALOR. **Dos mitades:** el SQL (`cerebro_registrar_deposito`) manda ese deal a **Incidencia** en vez de a «Por verificar», con el motivo en las notas; y el `Decisor` **prohíbe confirmar el depósito y repetir el importe**, y pide el comprobante original — sin eso el cliente seguía oyendo «recibimos su depósito de 5,000 GYD», que era falso. Probado de punta a punta en bloque revertido (ref inventada → Incidencia, ref buena → Por verificar) y banco 2/2 con matriz de 6 y 0 cambios | **lo que esto NO es:** no valida que el depósito exista —de eso ya se encarga el cruce— ni caza un dígito mal leído como el `20397544023399` del 10-ago, que sigue pasando el filtro **y es correcto**. Aquí solo se para lo que no puede ser un TransID. Falta verlo con un cliente real |
> | 🔴 | **Marcar «perdida» ESCONDE el deal de todo el tablero.** `loadDeals` (`src/app/(dashboard)/pipelines/page.tsx`) carga `status.is.null`, `open` y `won` de 7 días: **`lost` no entra en ninguna columna**. Hoy escondió tres a la vez, uno con 39.000 GYD de un cliente esperando. Y el botón de reabrir está DENTRO de la ficha que ya no se puede abrir: solo se sale por SQL | **WaCRM → Hermes.** O el filtro carga las perdidas recientes, o hace falta un interruptor «ver perdidas» |
> | 🟢 | **El vigilante avisaba de un deal ya descartado — ARREGLADO el 14-ago 04:0x UTC.** La consulta (que vive en el workflow `bTwsEJsmoAzsuOxm`, no en una función) filtraba por **etapa** pero nunca por **estado**, así que un deal marcado como perdido seguía cumpliendo la condición hasta que pasaban 24 h. Ahora exige `COALESCE(d.status,'open') = 'open'`: `lost` es «esto se descarta» y `won` es «ya se entregó», y de ninguno hay nadie esperando. Antes/después sobre el caso real: el deal fantasma de sanzjuanpastor llevaba **758 minutos** dando positivo y habría avisado unas seis veces más esta noche; ahora no aparece. Validado con `banco-sql.py` —que de paso ganó `--workflow`, porque los vigilantes viven fuera del Cerebro— y visto correr en producción a las 04:10: 0 avisos creados. Rollback: `ROLLBACK-v2-antes-sin-cruzar-solo-vivos.json` | ojo al leer la prueba de las 04:10: a esa hora el negocio está cerrado y la consulta ya tiene su guarda de horario, así que **lo que demuestra es que corre limpia**, no que el filtro sea lo único que la calla. Eso lo demuestra la consulta de antes/después |
> | 🟠 | **MMG no mandó el correo de un depósito real** — primer `sin_correo` de verdad. Yari (5926716394), 39.000 GYD, TransID `10397797355547` a las 10:45. El comprobante es bueno (pantalla Agent Cashin, destino 6762167, ID coherente con la secuencia de MMG) y el correo **no existe en el buzón del agente, ni en spam ni en papelera** — comprobado leyendo el buzón. La ingesta estaba viva (correos a las 10:50 y 11:32). La remesa se entregó igual | **libro ya cuadrado el 13-ago**: la fila se dio de alta a mano por indicación de Osmany, con `asunto = 'ALTA MANUAL - MMG NUNCA ENVIO EL CORREO'`, `gmail_message_id` NULL, atada al deal `ef442220` y con la comprobación entera escrita en `crudo`. El día cierra con **8 depósitos cruzados = 447.800 GYD**, que es exactamente el total de los envíos reales. **Lo que queda abierto es la causa**: MMG puede volver a no mandar un correo y hoy solo lo detecta el vigilante de depósitos sin cruzar |
> | 🟠 | **El objetivo se fija con la lectura equivocada y nadie lo corrige.** James Barrow escribió «$250,000.00», el bot lo leyó como USD y fijó objetivo de **65.000.000 GYD**. El cliente aclaró «Guyana Dollars» un minuto después y el objetivo se quedó, colgando el envío en «FALTAN 64.750.000». Cerrado a mano hoy | que una aclaración del cliente pueda **rehacer** el objetivo, no solo fijarlo |
> | 🟢 | **Número de Zelle normalizado en los DOS nodos — DESPLEGADO el 14-ago 02:0x UTC**, sin ver tráfico real todavía. Un CTE `cuenta` en `registrar_beneficiario_zelle` y en `Registrar zelle auto` deja el número de EEUU en **10 dígitos pelados** venga como venga (`+1 (469) 512-1137`, `469 512 1137`, `14695121137`). Al modelo se le sigue pidiendo que copie LITERAL —lo que importa es que no invente— y el formato se arregla en SQL, que es la vía que sí se sostiene. **Lo que NO se toca, y es lo que costó una segunda vuelta:** los correos; **cualquier prefijo internacional que no sea +1** (un `+53` cubano en una cuenta Zelle es un error del cliente y tiene que cantar: normalizarlo lo dejaba en `5358741800`, con pinta de número de EEUU); los 10 dígitos que empiezan por 0 o 1, que no son área válida; y lo que no se reconozca. **Y una segunda vuelta, por una pregunta de Humberto:** «¿y si un cliente de CUP manda su número sin +53?». Un depósito en CUP no pasa por aquí —los datos cubanos van por `gestionar_beneficiario` / `Registrar beneficiario auto`, que normalizan a los últimos 8 dígitos, y el `normUS` del `Snapshot final` ya rechaza 8 dígitos, 16 dígitos y 10 que empiecen por 5—, **pero mi guarda SQL aceptaba el 5 inicial y la de JavaScript no**: si el modelo pasaba un cubano como cuenta Zelle, quedaba en `5358741800` con pinta de EEUU. Alineado con el JS (`<> '5'`). Coste asumido, el mismo que ya asumía el JS: un número de EEUU con área 5xx escrito sin `+1` se guarda tal cual en vez de normalizarse — nunca se estropea, solo no se limpia. Validado con `banco-sql.py` (2/2, firma intacta, byte a byte) y la lógica probada contra 10 formas reales, cubanas incluidas. Rollback: `ROLLBACK-v2-antes-zelle-normalizada.json` | **falta el primer cliente real**. Y queda aparte **limpiar los 13 históricos** (Richel Moreno Ramos está dos veces): hay que reescribir `deals.notes`, que es la fuente, no la tabla derivada |
> | 🟠 | **Dos depósitos del 13-ago sin dueño**: `20397791629217` de 5.000 (13:10) y `10397804934619` de 10.000 (16:51). Nadie los ha reclamado | **Osmany**, junto con los ocho del sábado |
> | 🟡 | **Cuatro envíos quedaron en «Lista para transferir» al cierre**: 72.000 (desde las 09:55 de Guyana), 15.600, 24.700 y 14.300 — **126.600 GYD**. El de 72.000 lleva casi 6 h | mirar si es normal o si se olvidaron |
> | ✅ | ~~**El beneficiario se iba a OTRO deal cuando el envío estaba en Incidencia**~~ — el dinero en un deal y el beneficiario en otro; quien transfiere ve uno de los dos. Caso real: Yari, 13-ago | **desplegado el 13-ago 16:58 UTC**: `'incident'` añadido a `cerebro_resolver_operacion` en los **seis** nodos que la llaman. Por `pruebas/banco-sql.py` (nuevo, para nodos Postgres): 6/6 compilan con `PREPARE` y ninguna firma de parámetros cambia; efecto medido en bloque `DO` revertido (`ninguna`→`unica`). Probado con mensaje real 18 s después (`Registrar zelle auto`, deal 725a1786, sin error). Rollback: `ROLLBACK-v2-antes-incident-en-resolver.json`, o `banco-sql.py --revertir`. **OJO al efecto secundario:** una incidencia vieja que conviva con un envío nuevo ahora da `ambigua` y deriva a una persona |
> | ✅ | ~~**El PAT de GitHub estaba MUERTO (401)**~~ — la misma trampa silenciosa que la clave de n8n esa madrugada | **rotado por Humberto el 13-ago ~15:40 UTC**: verificado (200, scope `repo`), la 079 ya está copiada al repo. **OJO: el nuevo CADUCA el 11-nov-2026, el mismo día que la clave de n8n** — ese día mueren los dos a la vez |
> | ✅ | ~~**Las recargas entraban como «Remesa» y el bot pedía TARJETA**~~ (Yilian +5926595697, 13-ago, promo de Etecsa) | **hecho el 13-ago a mediodía (079)**: detección doble —`cerebro_registrar_deposito` titula `Recarga +tel` y marca `service_type='recarga'`; `recarga_en_curso` en `Contexto conversacion`— y el `Decisor` en modo recarga pide SOLO el número, nunca tarjeta, y dice «recarga» en vez de «transferencia». Banco 6/6 + 36 combinaciones 0 regresiones; DO-rollback sobre las conversaciones reales; 1 positivo de 30 conversaciones en 3 días (exactamente Yilian); dos mensajes reales en pruebas (la recarga confirma número sin pedir tarjeta, la remesa sigue idéntica). **Falta verlo con el próximo cliente real de recarga.** Detalle: final de `19-…md`. Rollbacks: `ROLLBACK-v2-antes-decisor.json` y `ROLLBACK-v2-antes-recarga-contexto.json`. OJO: el **notificador por etapa** aún dirá «remesa» al entregar una recarga |
> | ✅ | ~~**Arreglos 1 y 2 del `Decisor`**~~ | **hechos el 11-ago de noche**: pedir en genérico también antes del depósito, y callar la petición cuando el cliente dice que espera datos de un tercero. Banco 5/5 + 24 combinaciones. **El banco paró una versión que habría tumbado el `Decisor`** (uso de `const` antes de inicializar). Falta probarlos con tráfico real |
> | ✅ | ~~**Fallo 3 — la cifra falsa de la ráfaga múltiple**~~ | **hecho el 11-ago de noche**: con varios comprobantes en la ráfaga, **PROHIBIDO decir ninguna cifra**. Banco 4/4, 12 de 24 combinaciones cambian (las 12 de ráfaga múltiple), 0 regresiones |
> | ✅ | ~~**Ráfaga con varios comprobantes: el segundo se PIERDE**~~ | **hecho la madrugada del 12-ago**: `Snapshot final` publica la ráfaga entera, `cerebro_cruzar_depositos` (071) la cruza **todo o nada**, el deal vale la suma con un `DEPOSITO:` por comprobante, y el `Decisor` confirma **el TOTAL**. Banco 11/11 y 10/10, 256 combinaciones, 0 regresiones. **Ninguna de las 18 combinaciones de comprobante único se mueve.** Falta tráfico real. Ver `26-la-rafaga-sumada-y-el-saldo-del-envio.md` |
> | ✅ | ~~**El saldo del envío**~~ | **encendido la madrugada del 12-ago** para la vía Zelle/USD. `calcular_usd` apunta el objetivo al cotizar (sin tool-call nuevo: se probó una tool aparte y **el modelo no la llama**, 0 de 2). Probado con mensajes reales: 240 USD → 62.400, luego 315 USD → 81.900 **sustituyendo** al anterior. Migraciones 072-075 |
> | ✅ | ~~**Vigilante del envío que no completa**~~ | **hecho**: `Vigilante - envios incompletos` (`O1TqpAJXgRfKCiW6`), cada 10 min, migración **076**. Probado entero —incluido que el aviso SE CREA— abriendo la ventana horaria dentro de un bloque que se revierte. **Falta arrastrarlo a la carpeta `vigilante` a mano** (las carpetas solo se mueven desde el navegador) |
> | 🟡 | **Las otras tres tools de cálculo no apuntan objetivo** — solo `calcular_usd`. Un envío cotizado en GYD (`calcular_envio`, `calcular_inverso`, `calcular_usd_desde_gyd`) se comporta como siempre: sin objetivo, sin saldo. Cómo hacerles lo mismo está al final de `pruebas/candidato-calcular-usd-apunta-objetivo.js` | decidir si hace falta tras ver el Zelle funcionando |
> | ✅ | ~~**Plan de la auditoría del 11-ago**~~ | **completo el 11-ago** (063, 064, 065, variables): conciliación en 0, REVOKE total verificado, advisors 28→16 deliberados. Queda solo vigilar 24 h los `mensaje_fallido`; Hermes revisa la 065 al despertar |
> | ✅ | ~~**Rastro de webhooks** y su punto ciego~~ | **cerrado el 10-ago**, probado con mensaje real |
> | ✅ | ~~**Rotar la API key de n8n y el PAT de GitHub**~~ | **hechas el 10-ago**, las viejas revocadas |
> | ✅ | ~~**Migración 060:** borrar un deal deja la operación huérfana~~ | **hecha el 10-ago**, 8 divergencias cerradas |
> | ✅ | ~~**2E / ventana de 24 h**~~ | **cerrado lo que dolía el 11-ago**: alertas admin y «remesa completada» van por plantilla (probadas `delivered`); fase 3 del outbox **decidida NO por ahora** (Humberto) — construida y apagada por si cambia el cálculo |
> | ✅ | ~~**Plantillas de Meta**~~ | **aprobadas, PROBADAS y CABLEADAS el 11-ago**: `remesa_completada` entregada real por el enviador; `alerta_operativa` ya es el formato de las alertas del manejador — atraviesa la ventana de 24 h, **3/3 admins delivered** (el tercero por primera vez; era su contacto con teléfono pelado, corregido) |
> | ✅ | ~~**Colisión de instrucciones en el `Decisor`**~~ | **cerrada y PROBADA CON MENSAJE REAL el 11-ago 17:50**: la orden sale la última y el modelo la obedece. Banco 5/5 + 24 combinaciones. Beneficiario del envío de 13.000 GYD ya puesto. Ver `25-la-colision-de-instrucciones-en-el-decisor.md` |
> | 🟠 | **La tasa ya va en el contexto** (12-ago) — red contra el fallo de arriba: `Ultima cotizacion` devuelve la tasa vigente y el `Decisor` la dice, así que si el modelo calcula lo hace con la de hoy y no con una recordada. Banco 13/13, 432 combinaciones, 0 regresiones. **Falta la prueba buena: cambiar la tasa y ver si cotiza con la nueva — fuera de horario.** El SQL está en `27-…md` | probar esta noche |
> | 🔴 | **DSML — ENTENDIDO A FONDO, sin arreglo de fondo todavía.** Es un bug del proveedor: DeepSeek V4 emite una **variante degradada** de su propio marcado (`<｜｜DSML｜｜` con DOS barras; el canónico lleva UNA) que su parser no reconoce y cae en `content`. Reportado en NVIDIA, Microsoft Foundry y Cherry Studio. **No hay palanca nuestra**: se midió modelo (solo existen V4), nodo (1.4.8 es la última y no menciona DSML), memoria (0 filas), nº de tools, streaming, maxIterations y tamaño de prompt — ninguna lo cambia. **La tasa oscila 0–100% en minutos**, y en racha mala reintentar no sirve (10/10, 8/8). El parser está escrito y probado (`pruebas/candidato-parsear-dsml.js`); falta la tubería que ejecute la herramienta y vuelva al modelo | **Decidir si se construye.** Ver `27-el-dsml-entendido.md`. Hay banco que lo reproduce a voluntad: `pruebas/dsml.py` |
> | 🟠 | El agente no re-consulta un servicio en conversación viva | sin decidir |
> | 🟠 | **Fuga de razonamiento REAL al cliente** (12-ago, encontrada por las evals): el 10-ago 16:00 UTC un cliente recibió y **leyó** «El cliente dijo… Necesito saber… Le pregunto.» — `quitarRazonamiento` no caza razonamiento+respuesta en el mismo bloque sin marcador. Y NO es cosa vieja: el replay del 12-ago la reprodujo en vivo dos veces (reg-32635). Caso de oro listo para el banco del normalizador | **decidir si se arregla** (candidato por escribir; banco: doc 23) |
> | 🟠 | **Tandas de prompt 1 y 2-B DESPLEGADAS la noche del 12-ago.** Tanda 1: cotización dual, preguntar ante «Clasica tropical» y ante «pesos» ambiguo. Tanda 2-B: responder en el idioma del cliente (inglés probado real) y mapeos de «me mandas la cuenta». Todo por el banco (baterías completas, mejor-de-3, controles contra producción); mensajes reales de libro en español e inglés. Prompt 34.806→38.581 chars. Rollbacks: `ROLLBACK-v2-antes-prompt-tanda1.json` y `-tanda2B.json` (granulares) | **NO ha visto tráfico real** — mirar el 13-ago en marcha: pregunta común (tasa+monto), envíos USD, clientes en inglés |
> | 🔴 | **Tanda 2-C DIFERIDA con causa** (reglas 4, 6, 7 del arbitraje): el banco detectó que esa redacción **suprime a veces `registrar_beneficiario_zelle`** (caso 29922: 100% estable en producción, ~50% con el candidato). Rediseñar con otra redacción y probar con n≥5 en la familia Zelle. La redacción descartada queda en `pruebas/evals/candidato-prompt-tanda2.txt` como registro | rediseño, sin fecha |
> | 🟢 | ~~**Arbitrar los 70 casos de evals**~~ — **hecho por Humberto y procesado el 12-ago de noche**: 43 a oro tal cual, 6 corregidos (fallos reales que ahora se vigilan), 3 descartados, 18 pendientes de contexto/historial. Sus comentarios dejaron **10 reglas de negocio no escritas**: `REGLAS-DEL-ARBITRAJE-12ago.md` | quedan las **dudas devueltas** (final de ese doc) y reconstruir el historial de los condicionales |
> | 🟡 | **Plantillas de cambio de precio + broadcast** — texto cerrado con Osmany, `cambio_precio_mejora` y `cambio_precio_sube` **enviadas a Meta el 11-ago, en revisión** | esperar aprobación → sincronizar → mirar la `category` con que vuelven. Ficha: `PLANTILLAS-META-cambio-de-precio.md` |
> | 🟡 | **2F** — cortar `deals.notes` como fuente de verdad | sin prisa |
> | 🟡 | **Contabilidad y ganancias** — volumen ya hecho, falta el coste | **la hoja de Osmany** (`PEDIR-A-OSMANY-contabilidad.md`) |
> | 🟠 | **Sanear el `waba_id` al guardarlo** | **Hermes** — buzón `2026-08-11-0046` |
> | 🟠 | **Ocho depósitos sin dueño** — los del sábado (4.000 y 77.000 GYD) pueden tener a un cliente esperando | **Osmany** (`PEDIR-A-OSMANY-depositos-sin-dueno.md`) |
> | 🟡 | **Redacción** de las respuestas — el formato ya está, lo que *dice* no | toca prompt — **desde el 12-ago SÍ hay banco**: `pruebas/evals/evaluar.py` corre el prompt vivo contra la batería sin tocar producción (`PLAN-EVALS-conversaciones.md`). El mensaje real sigue siendo la puerta final |
> | 🟡 | Limpiar el Kanban y pantalla de historial | Hermes |
> | 🟡 | Combos, recargas automáticas y México completos | **37 preguntas a Osmany** |
> | 🔵 | Deuda de datos (10-16) y detalles menores | nada urgente |
>
> **Lo primero al abrir el 12-ago**, además de lo de arriba: el `Decisor` se
> desplegó anoche con el negocio cerrado y **no ha visto tráfico real**. La
> comprobación es una consulta que debe dar **0 filas**:
>
> ```sql
> SELECT o.id, o.status, o.quoted_source_amount
>   FROM remittance_operations o
>   LEFT JOIN remittance_beneficiaries b ON b.operation_id = o.id
>  WHERE o.status IN ('ready_to_transfer','deposit_verification')
>    AND b.operation_id IS NULL
>    -- Aisha (5926838966, 6.200 GYD): parada A PROPOSITO hasta el 13-ago, no
>    -- debe cruzarse. Sin esta linea la consulta canta todos los dias y se
>    -- aprende a ignorarla. QUITAR LA EXCLUSION cuando se cierre su recarga.
>    AND o.id <> '5a163c3d-8727-48bd-b919-16de32668756';
> ```
>
> **Al cierre del 11-ago da 0 filas.** El envío de 13.000 GYD ya tiene su
> beneficiario (`EMILIO MCNEIL`, aplicado a mano el 11-ago 21:21 UTC).
>
> **Y lo desplegado esta madrugada, que tampoco ha visto tráfico real.** La
> ráfaga múltiple es rara —una o dos veces por semana—, así que no basta con
> esperar a verla: hay que mirar que **el caso normal de UN comprobante siga
> igual que siempre**, que es lo que pasa cien veces al día.
>
> ```sql
> -- Los depositos de hoy y como quedo su envio. Con UN comprobante todo tiene
> -- que verse exactamente como ayer: un DEPOSITO por deal y sin linea de SALDO.
> SELECT d.title, d.value, s.name AS etapa,
>        (SELECT count(*) FROM depositos_mmg m WHERE m.deal_id = d.id) AS depositos,
>        (COALESCE(d.notes,'') LIKE '%TOTAL VERIFICADO%') AS fue_rafaga,
>        (COALESCE(d.notes,'') LIKE '%SALDO:%')           AS quedo_esperando
>   FROM deals d JOIN stages s ON s.id = d.stage_id
>  WHERE d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
>    AND d.created_at > current_date
>  ORDER BY d.created_at DESC;
> ```
>
> **`quedo_esperando` tiene que dar `false` en todas.** El saldo está apagado
> —no hay ningún objetivo fijado—, así que si aparece un `true` es que algo
> encendió la fase B sin querer y hay que mirarlo antes de seguir.
>
> **Con fecha:** el **13-ago** empieza la promoción de Etecsa y el bot cotizará
> recargas solo por primera vez.
>
> **El 2E está desbloqueado:** las plantillas `remesa_completada` y
> `alerta_operativa` están APROBADAS y sincronizadas en el CRM desde el 10-ago.

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

## ✅ La cadena entera del incidente del 10-ago — los cuatro eslabones

El susto de los 6.762.167 GYD no tenía una causa, tenía cuatro. Se cerraron
todos el mismo día. Detalle en `15-la-via-de-deposito-por-defecto.md`,
`10-vision-doble-lectura.md` y `14-lo-que-se-le-dice-al-cliente-sale-del-sql.md`.

| # | Fallo | Arreglo | Verificado |
|---|---|---|---|
| 1 | El bot dio la cuenta de Pay Merchant sin que el cliente la eligiera | **Agente `6762167` por defecto**, mapeo plano en el prompt | *"me mandas la cuenta"* → `6762167` |
| 2 | Solo dos orientaciones de lectura | **Cuatro giros** | de lado: 6/9 → 8/9 |
| 3 | Un importe sin referencia entraba como depósito real | **Guarda:** sin TransID → importe 0, a Incidencia | bloque revertido + en seco |
| 4 | El agente confirmaba —y llegó a **inventarse** una cifra— | El contexto sale del veredicto del SQL, y la imagen no reconocida tiene su propia orden | end-to-end |

**El orden importa para entenderlo:** sin el eslabón 1 no hay captura de
pantalla, y sin captura no hay deal fantasma. El fallo de visión fue el
**último** eslabón, no el primero. Costó media sesión verlo, porque el síntoma
visible era el importe absurdo.

> **Lo que más enseña de todo el día:** el eslabón 4 aparecio **dos veces y de
> formas distintas**. Primero el sistema le *ordenaba* confirmar el depósito
> pasara lo que pasara. Al quitar esa orden, el agente **se inventó 8.000 GYD de
> la nada** ante una imagen que el sistema había clasificado correctamente como
> «no reconocida». **Donde no hay instrucción, el modelo rellena el hueco con lo
> más frecuente del negocio.** El silencio del sistema no es neutral.

---

## ✅ El modelo narrando en voz alta, y el cliente en bucle (10-ago tarde)

**Cuatro respuestas salieron con el razonamiento del modelo delante**, a tres
clientes distintos: *"El cliente dijo \"Clasica tropical\" pero no eligió
claramente entre las dos. Necesito saber cuál de las dos quiere. Le pregunto."*

**El prompt ya lo prohibía** —*"PROHIBIDO narrar tus reglas, tu razonamiento o tu
proceso"*— y el modelo lo incumplió igual. Por eso **no se tocó el prompt**: se
puso un **filtro determinista** en `Normalizar formato`. Verificado contra los
275 mensajes que ha enviado el bot: caza los 4 filtrados y ni uno más.

Y en la misma conversación se vio un **bucle**: tres veces la misma pregunta,
tres veces la misma respuesta del cliente, hasta que entró Osmany. Un cliente
real llegó a recibir la pregunta de la vía **cinco veces**. Ahora, si el bot
repite una de sus **dos preguntas de opción cerrada** cuatro veces en una hora,
`Control de abuso` deriva por SQL. Calibrado con datos: umbral 4 → 1 disparo en
6 días; umbral 3 → 4, tres de ellos injustos.

Detalle, pruebas y vigilancia en `16-fugas-de-razonamiento-y-bucles.md`.

> **Lo que se repitió tres veces el mismo día y conviene no volver a discutir:**
> una prohibición en el prompt **no es un control**. Si algo tiene que pasar sí o
> sí, va en el SQL o en un nodo determinista.

---

## ✅ La rama de duplicados ya consulta el estado (10-ago)

Si el cliente reenviaba la **misma imagen**, `Dedup comprobantes` la paraba antes
del cruce y el `Decisor` le decía siempre lo mismo — *"recibimos su depósito,
lo estamos revisando"*— aunque el envío ya estuviera **entregado** o el depósito
ya se hubiera usado en otro envío. No movía dinero, pero creaba una
**expectativa falsa** de una segunda transferencia.

Ahora `Contexto conversacion` devuelve `dup_etapa` y `dup_valor` buscando por
`comp_id`, y el mensaje depende del estado real: *ya entregado*, *ya verificado*,
*en revisión por una persona*, o *en verificación*. Detalle en
`14-lo-que-se-le-dice-al-cliente-sale-del-sql.md`.

> **Ese cambio pasó `Contexto conversacion` de 1 a 2 parámetros**, y por ese nodo
> pasa TODO mensaje. Consulta y `queryReplacement` van siempre juntos.

> **Para probar duplicados hace falta enviar la MISMA foto dos veces.** Un solo
> envío no ejercita esa rama, y una foto distinta tampoco: el hash es lo que
> dispara el dedup.

---


## ✅ No prometer la transferencia sin saber a quién (10-ago)

El **10-ago** el bot le dijo a un cliente *"en breve le hacemos la
transferencia"* **30 segundos después** de que Osmany le pidiera por el mismo
chat los datos de quien recibe, que aún no había dado.

**Eran dos sitios, y uno no es el Cerebro:** el notificador por etapa
(`wGud0KGR6eMqqfMQ`) disparaba una plantilla fija al mover un deal a "Lista para
transferir" a mano. Por eso ningún arreglo del `Decisor` lo tocaba.

Ahora hacen falta **siempre los dos datos** —tarjeta y celular, o cuenta Zelle y
nombre— y el bot pide **exactamente el que falta**. Medido antes de exigirlo: de
9 beneficiarios de tarjeta cubana los 9 tenían ambos, y de 14 de Zelle los 14
tenían cuenta y nombre. No bloquea ningún caso legítimo.

Detalle, pruebas y reversión en
`17-no-prometer-la-transferencia-sin-beneficiario.md`.

> **La pista que lo delató fue la ortografía:** *"Su deposito"* sin tilde, igual
> que en un mensaje de dos días antes. Eso no es prosa del agente, es una
> plantilla — y buscar el patrón repetido ahorró mirar el prompt en balde.

---

## ✅ Qué se le pide al cliente y qué no se le promete (10-ago)

Cuatro cambios más en el `Decisor`, salidos de leer conversaciones reales y
**probados los cuatro mandando mensajes de verdad**:

1. **No preguntar la vía de depósito si ya depositó.** Medido: 14 mensajes así a
   8 clientes en 5 días; se suprimen esos y **ninguno de los 31 legítimos**.
2. **Dos notas del contexto se contradecían** — una prohibía prometer la
   transferencia y otra decía *"sale enseguida"*. El modelo obedecía a la
   equivocada.
3. **Pedir los datos en genérico** hasta saber la vía. De 9 comprobantes reales
   donde el beneficiario llegó después, **5 fueron tarjeta y 4 Zelle**: pedir
   *"la tarjeta y el celular"* fallaba en 4 de 9.
4. **Para Zelle hacen falta nombre Y cuenta.** La rama de "Zelle a medias" era
   **código muerto**: `s.datos_zelle` a secas daba el destino por sabido.

Detalle, cómo se siembra el estado para probar cada rama y los resultados
reales en `19-que-se-le-pide-al-cliente.md`.

> **La regla que sale de aquí:** una rama que no se ha visto producir un mensaje
> real **no está probada**. Tres fallos del 10-ago pasaron todas las
> comprobaciones previas y solo aparecieron mandando un mensaje.

---

## ✅ Los dos huecos del normalizador de formato (10-ago)

Humberto notó que algunas respuestas salían apelotonadas. Eran **dos causas
distintas**:

1. **El notificador por etapa no pasa por el normalizador.** Es otro workflow
   (`wGud0KGR6eMqqfMQ`) y manda sus mensajes directamente. Dos del 10-ago
   salieron de 152 y 138 caracteres **en una sola línea**. Ahora el salto de
   párrafo va escrito en el propio texto.
2. **El normalizador se retiraba ante un salto simple.** Daba por hecho que
   cualquier salto significaba formato bueno; ahora solo se retira si hay
   **párrafos de verdad** (`\n\n`).

**Verificado sobre los 349 mensajes del histórico:** 26 mejoran, **0 empeoran**,
ninguna cifra partida y ningún bloque de datos roto. Detalle en
`20-el-normalizador-y-sus-tres-huecos.md`.

> **Al añadir un mensaje al notificador por etapa hay que formatearlo a mano.**
> No hay red que lo recoja.

> **Pendiente y distinto:** el formato ya se lee bien, pero **la redacción** de
> algunas respuestas sigue siendo mejorable. Eso toca prompt y es otra
> conversación.

---

## ✅ Vigilante de la ingesta de depósitos (10-ago)

`Vigilante - ingesta de depositos MMG` (**`NiibUBRtOlOppmY4`**), cada 10 minutos:
**prueba la credencial de cada buzón** y avisa en el CRM si no se puede leer.

**No vigila el volumen de depósitos, y eso se decidió midiendo:** los huecos
legítimos en horario de negocio llegan a **4 h 05** (7-ago) y **3 h 50**
(5-ago). Con umbral de 3 h habría dado dos falsas alarmas en 5 días y el 10-ago
habría avisado solo 42 minutos antes. Además, el buzón de la app murió a las
00:23 y el de agente siguió alimentando el libro: un vigilante por volumen
global **no lo habría visto**.

Probado en sus tres caras, incluida la de fallo con una credencial rota a
propósito — que destapó que faltaba el tipo de aviso (**migración `058`**).

Detalle en `21-vigilante-de-la-ingesta.md`.

> **Lo que NO cubre:** que MMG deje de mandar correos, que se rompa el filtro
> del asunto, o que la visión lea mal la referencia. Para eso falta el segundo
> vigilante, el de la consecuencia — ver abajo.

---

## ✅ Vigilante de «cliente esperando sin cruzar» (10-ago)

`Vigilante - depositos sin cruzar` (**`bTwsEJsmoAzsuOxm`**), cada 10 minutos.
Un deal en «Por verificar» cuyo TransID **no está en el libro** pasados 15
minutos = hay un cliente esperando. Avisa en el CRM, solo en horario de
atención, y repite cada 2 h como mucho.

Cubre lo que el de la credencial no ve: que MMG deje de mandar correos, que se
rompa el filtro del asunto, un fallo de parseo, o **una referencia mal leída** —
como la del 10-ago a las 12:48, donde la visión leyó `20397544023399` y el
correo decía `20397544023299`, **un dígito**.

**Calibrado midiendo:** el correo llega casi siempre antes que el comprobante
(−1 a −17 min en 23 casos). Con umbral de 15 min habría avisado de los 9
depósitos de la caída y de 3 referencias mal leídas del 8-ago, todas legítimas.
Migración **`059`**. Detalle en `21-vigilante-de-la-ingesta.md`.

---



## ✅ No preguntar la vía si el cliente ya depositó (10-ago)

El bot preguntaba *"¿desde dónde va a depositar, app o agente?"* a clientes que
**ya habían depositado**. A uno se lo preguntó **tres veces** teniendo el
depósito verificado desde hacía una hora; contestó *"esos mensajes me
confunden"*. Medido: **14 mensajes así a 8 clientes distintos en 5 días**.

`Contexto conversacion` devuelve ahora `via_deposito_ya_usada`, atada al **envío
en curso** (un cliente puede abrir una segunda remesa y ahí la pregunta vuelve a
ser legítima). Si hay depósito, el `Decisor` prohíbe la pregunta y además le dice
al agente **por qué vía entró**, para que pueda responder si el cliente pregunta.

> **Este cambio tumbó el Cerebro 27 minutos al primer intento.** Ver
> `18-dos-caidas-silenciosas.md`: se validó una consulta y se desplegó otra.

---

## ✅ Migración 060 — borrar un deal deja la operación huérfana (RESUELTA el 10-ago)

`cerebro_conciliacion_operaciones` **debía dar 0 filas siempre** y el 10-ago
llegó a **7**. Ninguna es un trigger roto: son deals borrados a mano desde el
CRM. `trg_sync_operacion_desde_deal` es `AFTER INSERT OR UPDATE`, **sin rama
`DELETE`**, así que la operación espejo se queda colgada.

Existe `trg_liberar_depositos_al_borrar_deal` (BEFORE DELETE), que sí libera los
depósitos — el hueco es solo la operación.

**Lo que hay que hacer** (migración `060`): rama `DELETE` que pase la operación a `cancelled` en
vez de borrarla, para conservar la auditoría, y una limpieza única de las que ya
están huérfanas.

**Por qué corre prisa aunque no rompa nada:** mientras la conciliación dé ruido,
**la red que avisa de fallos silenciosos de la Fase 2 no sirve**. Si mañana un
trigger falla de verdad, nadie lo va a notar entre las huérfanas.

> Relacionado con la **deuda 13** ("un deal desapareció el 7-ago"). Ya no es un
> caso aislado: el 10-ago se borraron varios a lo largo del día. Es
> comportamiento normal de operador limpiando el tablero, no algo automático.

---

## ✅ El bot mudo en los chats asignados (10-ago; rematado el 11-ago con la 068)

> **Remate del 11-ago (migración `068`):** Humberto vio chats que seguían
> «pegados» asignados horas después de que el admin los dejara, y tenía razón
> a medias: la 056 era **perezosa** — liberaba solo cuando ese cliente volvía
> a escribir (y en esa pasada el bot respondía; se verificó con datos que
> ningún cliente llegó a quedarse sin respuesta por esto). Pero en el CRM
> había 11 chats asignados, alguno desde el día 5, incluidos 7 de antes de la
> 056 con `assigned_at` NULL. Ahora el vigilante de chats atascados **libera
> proactivamente** cada 5 min las asignaciones manuales caducadas (misma
> condición del CTE de la 056; las derivaciones del bot siguen sin caducar).
> Primera pasada real: 11 liberados, quedaron solo las 3 del bot. Rollback:
> `ROLLBACK-068-avisar-chats-atascados-antes.sql`.

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

## ✅ Osmany como admin verificador de depósitos (11-ago 14:15 UTC, pedido «para ya»)

Osmany (`5218445335572`) reenvía comprobantes al número del negocio para
verificarlos cuando el bot no lo hizo. Hasta hoy lo hacía **disfrazado de
cliente** (el bot le contestaba con el guion de cliente y le creaba deals en
su conversación). Ahora:

- Su contacto lleva la etiqueta **`admin`** (`contact_tags`).
- La rama admin del `Decisor` tiene el comando nuevo **`verificar`**: si el
  lote trae comprobante, responde **el veredicto del SQL en seco y sin
  modelo** — VERIFICADO (TransID, importe, método, «queda consumido») /
  YA RECLAMADO / DEPOSITO ANTIGUO / SIN CRUCE (ref e importe leídos). Va por
  la ruta `comando` existente (`Liberar chat` → `Confirmar al admin`), sin
  nodos ni conexiones nuevas: solo el jsCode del Decisor y una rama
  `WHEN $2='verificar' THEN $1` en el CASE del SQL.
- Sus textos que no son comandos → silencio (como los demás admins); sus
  comandos disponibles: `liberar <numero>`, `tasa <moneda> <valor>`, `tasas`.
- **Segunda pasada el mismo día (14:30 UTC):** comprobante REPETIDO → el
  admin recibe «YA REGISTRADO: ese comprobante ya tiene su deal (etapa,
  importe). No se creó nada nuevo» — antes le respondía silencio. El dedup
  río arriba ya evitaba el deal duplicado; solo faltaba informar.

**ESPECIFICACIÓN DE HUMBERTO para la noche (11-ago, decidida — ya NO es
pregunta abierta):** el flujo manual de Osmany debe quedar así:
1. Comprobante limpio (casa con el correo, sin consumir, sin deal) →
   **crear el deal** (como hoy) + consumir + veredicto. Él lo mueve luego a
   donde pertenezca. ✅ ya funciona.
2. Ya consumido → decírselo **y añadir QUIÉN lo consumió** (deal/cliente) —
   hoy solo dice «ya reclamado»; ampliar `cerebro_cruzar_deposito` o
   consulta aparte para traer el deal consumidor. 🌙
3. Ya tiene deal (comprobante repetido) → informar sin crear. ✅ hecho 14:30.
4. **Incidencia (no casa / dudoso / antiguo) → NO crear deal en el flujo
   manual** — solo el informe. Hoy sí lo crea y lo manda a Incidencia como
   a un cliente. Toca `cerebro_registrar_deposito`/`cruzar` (funciones
   compartidas del camino del dinero) → SOLO fuera de horario, con el
   truco del bloque auto-revertido y regresión completa. 🌙
El objetivo declarado: registrar los depósitos de clientes que el bot no
verificó, sin basura de incidencias en el tablero del admin.

Regresión de cliente tras el cambio: verificada con mensaje real (15.000 →
45.000 CUP). Copia previa: `ROLLBACK-v2-antes-admin-verificar.json`.
Los tres funcionan igual si algún día se etiquetan más números admin.

## ✅ El notificador ya no avisa dos veces ni pierde alertas (11-ago 15:00 UTC)

Dos cambios en `WaCRM - Notificar cliente por etapa del deal`, pedidos y
verificados el mismo día (copias: `ROLLBACK-notificador-antes-incidencia-callada.json`
y el estado con plantilla de admin queda dentro del historial del workflow):

1. **Incidencia → Entregada = silencio al cliente** (criterio de Humberto):
   una incidencia la atendió una persona y el cierre se lo dio esa persona
   (captura incluida); mover el deal después es contabilidad, no noticia.
   Probado con deals reales: camino normal → plantilla entregada y leída ✓;
   camino Incidencia→Entregada → nada al cliente ✓.
2. **Los avisos de ADMIN del notificador van como plantilla `alerta_operativa`**
   (incidencia, derivación, límite, cruce aproximado). Se descubrió en la
   propia prueba: el aviso «deal en INCIDENCIA» salió como texto y murió por
   ventana de 24 h delante de nosotros. Con plantilla: **delivered** el mismo
   aviso 2 minutos después. (Mismo patrón que el manejador de la madrugada.)

## 🟠 DSML — el modelo escupe sus tool-calls como TEXTO (11-ago tarde, contenido pero VIGILAR)

**Qué pasa:** desde las ~14:30 UTC del 11-ago, DeepSeek devuelve a veces sus
tokens de tool-call (`<｜｜DSML｜｜tool_calls>…`) como texto del mensaje en vez
de ejecutar la herramienta. Intermitente (~4 de 5 fallando en la peor racha):
huele a formato nuevo desplegándose por porcentaje del lado del proveedor. El
nodo comunidad va en su última versión (1.4.8, sin hotfix aún). Histórico
completo: 2 casos previos (9-ago y este), 4 el 11-ago — **todos en la
conversación de pruebas, cero clientes reales tocados**.

**Las dos redes puestas el mismo día (11-ago 14:31 y 14:45 UTC):**
1. `Respuesta valida?` tiene condición nueva: output con `DSML` **jamás se
   envía** (id `dsml-guard-11ago`).
2. `Normalizar formato` **lanza error** si ve DSML → el manejador libera el
   lote → el cron lo reintenta (hasta 3) → si persiste, deriva a humano con
   aviso. Cliente: respuesta al reintento o atención humana, nunca basura ni
   silencio. Desplegado con el banco: 413 mensajes históricos, cero
   regresiones (`ROLLBACK-v2-antes-normalizar-formato.json`).
   **Trampa que casi lo anula:** el nodo llevaba `onError:
   continueRegularOutput` (herencia de «el formato jamás tumba un envío») y
   el throw se convertía en un item con `error` que acababa en SKIP
   silencioso. Se le quitó el `onError` — **un throw solo sirve si el nodo
   puede fallar de verdad.**
   **Verificado punta a punta a las 14:45 UTC:** fallo del modelo →
   ejecución error (29667) → manejador libera y avisa (29669, 16 s después)
   → reintento del cron → respuesta correcta entregada («40.000 → 120.000
   CUP») **33 segundos después del fallo**.

**Falsa pista que costó un rato:** el ciclo desactivar/activar pareció
curarlo (una prueba pasó a las 14:37) y era suerte — la siguiente volvió a
fallar. No es estado de n8n; es el proveedor.

**Vigilancia:** si la tasa de fallo sube a permanente, ni 3 reintentos
salvan y todo acabará derivado a humanos — ese día: mirar si salió hotfix
del nodo (`npm view n8n-nodes-deepseek-chat-model version` > 1.4.8) o si
DeepSeek documentó el formato nuevo. Los avisos del manejador (plantilla
`alerta_operativa`) harán de termómetro: cada racha de reintentos agotados
avisa sola.

### 11-ago 21:50 — ese día llegó: los 3 reintentos se agotaron

Durante la prueba de la colisión del Decisor (ver
`25-la-colision-de-instrucciones-en-el-decisor.md`) el modelo devolvió DSML
**tres veces seguidas** — `30539`, `30548`, `30551` — y el cliente **no
recibió nada**. A las 14:45 el reintento salvó la papeleta; a las 21:50 no.

Y hay un agravante nuevo: **cuando el contexto ordena explícitamente llamar
una tool, el modelo intenta el tool-call y por tanto entra más veces en la
zona donde el DSML aparece.** El arreglo del Decisor de esa noche hace que
esto se dispare en un caso más — el de Zelle con comprobante — que antes
simplemente no llamaba a nada.

**No se pudo comprobar si la derivación a humano funciona al agotarse**: el
depósito de la prueba se restauró con reintentos aún en vuelo y se contaminó
el final. Pendiente de verlo en el próximo caso real.

**Dos caminos, no excluyentes, para cuando se decida:**
1. **La causa:** que la guarda, en vez de tirar el lote, **parsee el DSML y
   ejecute la herramienta**. El texto trae `name`, `nombre` y `cuenta`
   perfectamente legibles — es XML feo, pero es parseable.
2. **La consecuencia:** que al agotar los reintentos el cliente reciba algo
   en lugar de silencio.

`pruebas/candidato-normalizar-dsml.js` **es byte a byte lo que ya corre en
producción** (5.709 caracteres, comparados el 11-ago): ahí no hay nada
pendiente de desplegar.

## 🟠→✅ Los fallos del Decisor del 11-ago — 1 y 2 HECHOS esa noche, queda el 3

> **Desplegado el 11-ago con el negocio cerrado**, por el banco (`--perfil
> contexto`), 5/5 en batería y 24 combinaciones sin regresión.
>
> - **Fallo 1 (pedir en genérico también antes del depósito):** la regla del
>   doc 19 vivía dentro de `if (s.comprobante ...)`, así que solo actuaba con el
>   comprobante en la mano. Ahora hay una rama pre-depósito
>   (`viaSinDefinir && (abiertos > 0 || esPregunta)`).
> - **Fallo 2 (el cliente espera datos de un tercero):** `esperaTercero` sobre el
>   texto. Y **no se añade una nota que contradiga la petición: se SUPRIME la
>   petición** — la lección de esa misma noche. En la matriz se ve: donde antes
>   salía «FALTAN DATOS» o «NO SABEMOS A QUIEN», ahora sale la de esperar.
>
> **El banco evitó un incidente.** La primera versión definía `esperaTercero`
> junto a `esPregunta` (línea 300) pero la usaba en la 237: zona muerta temporal.
> Habría tumbado el `Decisor` **en todo mensaje con comprobante y destino
> desconocido**. Salió en rojo con `Cannot access 'esperaTercero' before
> initialization` y no llegó a producción. Es exactamente para lo que se montó.
>
> Copias: `ROLLBACK-v2-antes-decisor.json` (estado previo a esto) y
> `ROLLBACK-v2-antes-decisor-colision-11ago.json` (previo al arreglo de la
> colisión, preservado a mano porque el banco reutiliza el nombre).
>
> **El fallo 3, la mitad que dolía, también quedó hecho esa noche.** Con varios
> comprobantes en la misma ráfaga el `Decisor` ya **no dice ninguna cifra**: la
> que sobrevive al colapso de `Snapshot final` no es el depósito, es un trozo, y
> decirla es peor que callarla. Banco 4/4; cambian las 12 combinaciones de
> ráfaga múltiple y ninguna de comprobante único.
>
> **Reproducido el turno real de Melih (11:38:45) contra el código ya
> desplegado:** ahora sale la nota *«PROHIBIDO pedirle "la tarjeta y el
> celular"… pídeselos EN GENÉRICO»*. Ese turno era el `Ok` de la clienta, un
> lote **sin comprobante** — exactamente el hueco del fallo 1.
>
> **Lo que sigue abierto:** el comprobante que se pierde. De los 27.000 de Melih
> no queda registro en ninguna parte; el cliente ya no recibe una cifra falsa,
> pero los depósitos hay que sumarlos a mano. Eso es `Snapshot final`.
>
> **Y falta la prueba con tráfico real** de los tres.

## Los fallos del Decisor vistos el 11-ago (texto original del diagnóstico)

Salieron de leer entera la conversación con **5926299943**
(`f09bec52-3f25-46fb-bcc2-882307b11e3f`, 11-ago 13:28–13:38 UTC). El depósito
acabó bien (18,200 GYD, VERIFICADO contra el correo, TransID exacto) y la
confirmación fue con veredicto del SQL — lo roto es de conversación, no de dinero:

1. **Pidió «tarjeta y celular de quien recibe en Cuba» sin saber la vía de
   entrega** (13:31:41 y 13:32:43) y el cliente tuvo que corregir: «Es por
   zell». El criterio del doc 19 (pedir EN GENÉRICO hasta saber la vía; 4 de
   9 beneficiarios reales eran Zelle) se aplicó en el flujo del comprobante
   pero **la rama Zelle/servicios pre-depósito quedó fuera**. Arreglo: mapeo
   plano en el `Decisor` para esa rama.
2. **No escuchó «estoy esperando que me manden la cuenta» (×3)** y pidió los
   datos del que recibe **4 veces en 5 minutos** (13:33:28, 13:34:24,
   13:35:15, 13:38:30 — la última justo después de «Si en cuánto me lo
   envíen»). Arreglo: instrucción plana «si el cliente dice que espera los
   datos de un tercero → acusar recibo y esperar, sin repetir la petición».
   Nota: el cortacircuitos de bucles NO cubre esta pregunta (vigila las dos
   de opción cerrada); si reincide tras el arreglo, valorar añadirla.

3. **Ráfaga con VARIOS comprobantes** (caso Melih 5926131647, 11-ago 15:32):
   mandó 2 comprobantes juntos (27.000 + 300 = sus 105 Zelle); la visión leyó
   AMBOS perfectos pero `Snapshot final` colapsa a UN comprobante y el de
   27.000 se descartó en silencio. La red funcionó a medias: deal a
   Incidencia con la alerta «mandó MÁS de un comprobante», nada consumido,
   admins avisados — pero el 27.000 leído se tiró. Arreglo: o procesar
   todos, o responder «recibimos sus N comprobantes, los revisa una
   persona» SIN cifras. Y de propina: **el Decisor citó "300 GYD" con el
   importe marcado dudoso** — viola el doc 14; candado a esa rama.
4. ~~Un «SKIP» literal llegó a un cliente~~ — **FALSA ALARMA del 11-ago,
   resuelta al releer el doc 22**: es el caso ÚNICO ya documentado y
   arreglado el 10-ago mismo (18:05 Guyana = 22:05 UTC, de ahí la
   confusión). El arreglo (orden invertido de la tubería + guarda de
   última línea) está desplegado y verificado en el grafo vivo; cero
   fugas desde entonces. Lección para el que audite: **el doc 22 se relee
   ANTES de declarar una fuga de SKIP como nueva** — y las horas de los
   docs van en Guyana, las de la base en UTC.

**Cómo hacerlo sin romper nada** (doctrina completa): fuera de horario;
releer `11-lenguaje-deliberativo-rompe-deepseek.md` antes (mapeo plano, cero
prosa deliberativa); copia `ROLLBACK-v2-antes-*` del Cerebro; probar la rama
Zelle sembrando el estado + **regresión de remesas completa** (la prueba que
nunca se salta); y verificar con mensajes reales, no en seco.

**Contexto del diagnóstico (11-ago, tras leer TODAS las conversaciones del
día):** la sensación de «errático» de Humberto es real pero localizada — los
fallos de hoy son TODOS de la misma familia (gestión conversacional de los
datos del beneficiario en la rama Zelle/servicios, la menos cubierta, que
hoy concentró el tráfico). El núcleo del dinero estuvo perfecto en las 4
conversaciones con bot: cotizaciones exactas (200→52.000, 220→57.200),
confirmaciones atadas al SQL, cruce verificado con TransID exacto. Nada del
Decisor/prompt/modelo cambió desde el 10-ago por la tarde.

## 🔴→✅ INCIDENTE 11-ago: el bot mudo 11 horas por la rotación del HMAC

**Lo que pasó:** la rotación de `CEREBRO_WEBHOOK_SECRET` de la madrugada dejó
las dos puntas desparejas: n8n validaba la clave NUEVA desde las 02:20, pero
WaCRM siguió firmando con la VIEJA — la clave nueva se escribió en
`/home/ubuntu/wacrm/.env.local` y **el proceso corre desde
`/home/ubuntu/wacrm-deploy`** (el `cwd` del pm2). El Cerebro rechazó TODA la
entrada de clientes de 02:20 a 13:15 UTC: **15 mensajes de 7 conversaciones,
2 con comprobante**, sin bot y sin una sola alarma. Lo destapó Humberto
preguntando por un cliente concreto (5927100574).

**Por qué la verificación de la madrugada no lo cazó:** la prueba firmada fue
directa al webhook del Cerebro — ejercitó la validación de n8n, **no la firma
de WaCRM**. La regla del proyecto aplicada en contra: una prueba que no
produce el efecto real de punta a punta no prueba nada. La prueba buena era
un WhatsApp real, y no se hizo hasta la mañana.

**Por qué el vigilante no gritó:** `cerebro_avisar_mensajes_perdidos` (061)
solo miraba `whatsapp_webhook_log.procesado=false` — pérdidas
WhatsApp→WaCRM. Aquí WaCRM procesó perfecto; lo que faltó fue el
`session_event`. Punto ciego.

**Arreglos, todos el mismo día 11-ago (13:15–13:30 UTC):**
1. Clave nueva en `wacrm-deploy/.env.local` (verificada por hash) + pm2
   restart → cadena confirmada con WhatsApp real de Humberto: lote
   `completed` y respuesta del bot en 20 s.
2. **Migración `069`**: el vigilante de mensajes perdidos ya ve el tramo
   WaCRM→Cerebro (mensaje de cliente sin `session_event` a los 10 min →
   aviso `bot_no_recibio`, suprimido si un humano ya contestó). Su primera
   pasada real avisó de los 4 clientes sin atender (12 notificaciones).
3. Carpeta trampa marcada: `wacrm/.env.local` ya no lleva el secreto y
   avisa en un comentario de que el vivo es `wacrm-deploy`. ARRANQUE
   actualizado con cómo comprobar host y carpeta antes de tocar un env.

**Afectados que necesitaron atención a mano:** Norma (5926800266, comprobante,
3 h esperando), Luis Peres (5927317368, comprobante), Melih (5926131647),
JoseM (5927674896); Alidannis y Yoandrys ya los cubría Osmany.

## ✅ Seguridad — HMAC rotado el 11-ago tras exposición

**El 11-ago Humberto pegó `CEREBRO_WEBHOOK_SECRET` en el chat** (junto al
entorno de Easypanel) → se rotó esa misma madrugada, con el criterio de
siempre: Humberto generó el valor en un fichero local, y el valor viajó por
tuberías (nunca por la conversación) a los dos lados — `.env.local` de WaCRM
en **oracle** (`/home/ubuntu/wacrm/`, pm2 restart) y `CEREBRO_WEBHOOK_SECRET`
de n8n en Easypanel (lo pegó Humberto, restart 02:20 UTC). Verificado con
mensaje firmado con la clave nueva: ejecución 28294 `success`, lote
`completed`, respuesta correcta. 0 webhooks de clientes en el hueco.

Dos cosas que salieron de ahí y conviene no olvidar:

- **WaCRM vive en `oracle` (129.159.93.221), no en el VPS de Hermes.** En
  `hermes-vps` (193.106.248.46, el host de Easypanel/n8n) hay un
  `/root/wacrm/.env.local` que es una **copia muerta** — a punto estuvo de
  comerse la rotación. `dig wacrm.onlinefreedom.site` antes de tocar nada.
- 🟡 **El `?secret=` de la URL del webhook conserva el valor viejo (quemado).**
  Al v2 le da igual (valida la cabecera HMAC y el env var tiene precedencia en
  el código de WaCRM), y el v1 está apagado. Pero **si algún día se activa el
  rollback al v1, hay que rotar ese `?secret=` también** — está en la config
  del endpoint en la base de WaCRM.

## ✅ Seguridad — sin secretos expuestos desde el 10-ago

| | Qué | Estado |
|---|---|---|
| 1 | ~~Token de GitHub de **Hermes** expuesto en Telegram~~ | ✅ **Revocado el 7-ago.** Sustituido por una **deploy key SSH** generada en el VPS: la privada no sale de la máquina y solo escribe en `wacrm`, no en toda la cuenta |
| 2 | ~~**Revocar la API key de n8n** usada durante la Fase 1~~ | ✅ **Rotada y revocada el 10-ago.** La nueva se verificó antes de borrar la vieja |
| 3 | ~~**Rotar el PAT de GitHub de `~/.github-token`**~~ | ✅ **Rotado y revocado el 10-ago.** Scope `repo`, caducidad 08-nov-2026. Se comprobó la escritura *sin escribir nada* (permiso `push` del repo) antes de revocar |

**Cómo se hicieron el 10-ago, por si hay que repetirlo.** Humberto generó las
dos claves nuevas y escribió él mismo los ficheros —así el valor no pasa por la
conversación, que era justo el problema— y solo después se revocaron las viejas.
El orden importa: rotar corta el acceso, y el de GitHub es por donde va el buzón
de Hermes. Con la vieja aún viva, un fichero mal pegado se arregla en un minuto.

Comprobado tras rotar: GitHub con scope `repo` y `push: true`, n8n con los 100
workflows y los cuatro vigilantes activos.

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

### 🔴 13-ago, primer día de la promo: el DSML se comió la cotización

La promo se activó sola y bien. `cerebro_servicio_get('recargas')` devolvía
`PROMOCION VIGENTE HOY: 600 CUP x6, 6200 GYD, valida hasta el 16/08` con
`requiere_humano = false`. **La pieza nueva funcionó.**

Lo que falló fue aguas arriba. Yilian Barbara Hernandez (`5926595697`), 08:51:

| | |
|---|---|
| Lo que había en la base | 600 CUP ×6 → **6.200 GYD** |
| Lo que sabía la clienta | *"siempre pongo es de 6200"* — **correcto** |
| Lo que dijo el bot | *"500 CUP por **2.500 GYD**"*, y luego *"serían **6.200 CUP**"* |

Siete ejecuciones en esa conversación (`35550`–`35583`), **ninguna llamó a una
sola herramienta**. Las dos primeras murieron por DSML; los reintentos
contestaron de memoria. El precio salió de la imaginación del modelo con la
respuesta correcta a una llamada de distancia.

**Lo que esto enseña, y no es sobre recargas:** una respuesta inventada no se
distingue de una buena. El error de DSML se da por resuelto en cuanto hay
*alguna* respuesta, y nadie mira si llevaba datos detrás. Mientras el modelo
decida si llama o no, cualquier dato que dependa de una tool es opinable.
Es el argumento de Humberto —*lo que usa determinismo no falla*— aplicado a
cotizar.

**No se tocó nada.** Queda para verlo con calma.

---

## 🟡 Un comprobante duplicado no levanta la mano (13-ago)

`5926731279` mandó dos veces el mismo fichero (hash `68be412d…`) el 12-ago a las
18:11 y 18:13. Los dos salieron por duplicados, y con razón: **ese comprobante
ya lo había procesado Osmany el 10-ago a las 14:43** desde su número de admin
(`5218445335572`), y el depósito `10397460289689` (20.000 GYD, del libro del
09-ago) ya estaba consumido.

El sistema decidió bien. El problema es lo que vino después:

```sql
SELECT count(*) FROM notifications
 WHERE conversation_id = '148ecdc4-ef08-4a66-b638-c45100f1cdea';  -- 0
```

Al cliente se le dijo *"lo estamos revisando y en breve le confirmamos"* y **no
se le dijo a nadie**. El deal sigue en «Solicitada» con valor 0 y el cliente
esperando. Si la rama de duplicados promete que una persona lo mira, tiene que
haber una persona a la que se le avise — como ya hace el vigilante de depósitos
sin cruzar.

**No se tocó nada.** Queda para verlo con calma.

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

## ✅ Cierre contable del libro anterior al CRM (11-ago noche)

**354 depósitos anteriores al 3-ago-2026 marcados como consumidos**, decisión de
Humberto: *«el CRM lo iniciamos el día 3, lo anterior se puede dar por consumido
sin problema»*. Iban del 31-dic-2025 al 2-ago-2026 y sumaban **54.017.132 GYD**.

`depositos_mmg` pasa de **428 sueltos a 74**, el más antiguo del 3-ago. Todos
llevan **el mismo `consumido_en` al segundo**, así que se distinguen de un
vistazo de los consumos reales:

```sql
-- los del cierre en bloque
SELECT count(*), consumido_en FROM depositos_mmg
 WHERE deal_id IS NULL AND consumido_en IS NOT NULL
 GROUP BY consumido_en HAVING count(*) > 100;
```

**Efecto secundario, menor pero real:** si algún día llega un comprobante de uno
de esos 354, el cruce dirá `ya_reclamado` («ese depósito ya se usó en otro
envío») en vez de `deposito_antiguo`. Los dos mandan el deal a Incidencia, así
que el resultado no cambia — solo el texto que ve el cliente.

### Lo que queda libre, y la pregunta que sustituye a «los ocho sin dueño»

| Día | Libres | Suma GYD |
|---|---|---|
| 03-08 | 25 | 1.333.520 |
| 04-08 | 11 | 848.980 |
| 05-08 | 3 | 147.760 |
| 06-08 | 6 | 545.999 |
| 07-08 | 2 | 372.500 |
| 08-08 | 4 | 119.000 |
| 09-08 | 4 | 886.520 |
| **10-08** | **14** | 474.100 |
| **11-08** | **5** | 1.154.130 |

Los **25 del día 3** son casi seguro de la misma naturaleza que los 354 (el CRM
abrió ese día); Humberto decidió **dejarlos por ahora**.

**Los 19 de los días 10 y 11 son los que merecen mirada**: son de días con el
Cerebro ya funcionando, así que o el cliente no mandó comprobante, o el sistema
los perdió. Y de un mecanismo que los pierde ya sabemos: la ráfaga múltiple —
los dos de Melih venían justo de ahí. Eso convierte la pregunta abierta con
Osmany en algo concreto: **19 depósitos con fecha e importe**, en vez de una
lista suelta de ocho.

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

## ✅ La ventana de 24 h — cerrada para lo que dolía (11-ago de madrugada)

**Las dos fugas reales quedaron tapadas con plantillas, probadas con envíos
de verdad:**

1. **Alertas al admin** → el manejador manda `alerta_operativa`: 3/3 admins
   `delivered`, incluido el número que moría por ventana y el tercero que
   jamás había recibido una (su contacto en WaCRM tenía el teléfono pelado;
   corregido). Copia: `ROLLBACK-manejador-antes-plantilla-alerta.json`.
2. **«Su remesa fue completada» al cliente** (el fallo del 10-ago con un
   cliente real) → el notificador por etapa manda la plantilla
   `remesa_completada` con el importe como parámetro. Probado con un deal
   real movido a Entregada: `delivered`. Copia:
   `ROLLBACK-notificador-antes-plantilla-completada.json`.

**Por qué con esto basta:** las respuestas del bot son siempre *respuestas* —
el cliente acaba de escribir, la ventana está abierta por definición. Los
únicos envíos fuera de ventana eran justo esos dos.

**Riesgo residual, pequeño y aceptado:** el aviso «depósito verificado» de
verificación manual sigue en texto (no hay plantilla para él). Solo fallaría
si la verificación manual llega >24 h después del último mensaje del cliente,
que casi nunca pasa (el comprobante es reciente por definición). Si algún día
duele: aprobar una plantilla `deposito_verificado` y calcarle el patrón.

**La fase 3 del outbox (el corte) se decidió NO hacerla por ahora** — decisión
de Humberto, 11-ago: añade hasta 30 s de latencia a cada respuesta y crea un
modo de fallo silencioso (enviador parado = nadie envía y nada grita), a cambio
de proteger contra un caso raro. Todo queda construido y probado por si cambia
el cálculo: enviador `K4ijL3NzmY1VX7XI` apagado, interruptor `outbox_activo`,
migraciones 066/067, plan del recableado en `24-plan-arreglos-auditoria.md`.
**Si un cliente llega a recibir una respuesta doble, ese día se enciende** —
con su vigilante de filas atascadas, que es el requisito que le falta.

### (histórico) 🟠 La ventana de 24 h de WhatsApp

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
| 11 | **8 de 28 deals entregados no tienen beneficiario registrado** (eran 2 el 8-ago). Se entregó dinero y el sistema no sabe a quién. Se resolvió por fuera. El arreglo del 10-ago evita que siga creciendo, pero no reconstruye los que ya están |
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
