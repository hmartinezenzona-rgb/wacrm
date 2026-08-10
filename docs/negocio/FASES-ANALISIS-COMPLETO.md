# Las tres fases del spec — balance completo

Análisis de `spec-gpt/fase_1.txt`, `fase_2.txt` y `fase_3.txt` contra lo que hay
hoy en producción. **9 de agosto de 2026.**

Complementa `FASE2-ANALISIS.md`, que sigue vigente para el detalle de la Fase 2.
Aquí está lo que aquel documento no podía tener: la Fase 3 y el orden global.

---

## 1. Dónde estamos de verdad

| Fase | Estado | Detalle |
|---|---|---|
| **1** | ✅ **Completa** | Los 10 puntos, las 7 pruebas A-G, en producción desde el 5-ago |
| **2** | 🟠 **1 de 6 tramos** | Solo 2B (depósitos + hash transaccional) |
| **3** | ⬜ **Sin empezar** | Nunca se había leído |
| 4 (SaaS) | ⬜ No toca | El propio spec dice que no se implemente |

**Matiz que importa:** la mayor parte del trabajo de estas dos semanas **no sale
del spec**. El cruce con plan B, la doble lectura de fotos giradas, la ventana de
silencio, los servicios, el segundo buzón de correo, el nodo sin pensamiento —
nada de eso está en las tres fases. Salieron de medir el sistema real.

El spec es un buen mapa arquitectónico, pero **no es la lista de lo que duele**.

---

## 2. Fase 1 — completa, con una desviación consciente

Todo cubierto. Queda **una sola cosa** del spec sin cumplir, a propósito:

> **Punto 8: "No uses secreto en query string".**

El `?secret=` de la URL de WaCRM **sigue vivo**. No es un olvido: es lo único que
mantiene utilizable el Cerebro v1 como rollback de 30 segundos. El HMAC ya está
implementado y es lo que usa el v2.

**Se retira cuando se jubile el v1**, no antes. Está anotado en `PENDIENTES.md`
punto 8.

---

## 3. Fase 2 — menos bloqueada que cuando se analizó

De las cinco preguntas que dejé abiertas, **tres se respondieron solas** desde
entonces:

| Pregunta | Entonces | Ahora |
|---|---|---|
| ¿Dos remesas a la vez? | cero casos observados | ✅ **Sí pasa** (Humberto, 8-ago) |
| ¿Feature flags dónde? | por decidir | ✅ `cerebro_config` |
| ¿Los 83 depósitos sin consumir? | sin medir | ✅ Medido: 76 previos al arranque + 11 reales |
| ¿Quién cierra los deals? | abierta | ❌ Sigue abierta (12 en "Entregada" con `status='open'`) |
| ¿Los 4 hashes sin deal? | sin comprobar | ❌ Sigue sin comprobar |

**La primera es la que más cambia.** Con "sí pasa" confirmado, la Fase 2 deja de
ser una mejora arquitectónica y pasa a ser **el arreglo de un fallo real**: hoy
`registrar_beneficiario_zelle` coge el deal abierto más reciente y puede escribir
el destino de una operación en otra (deuda 14).

Queda **una sola decisión** antes de poder escribir código: cómo se inyecta el
`operation_id`. Sigo recomendando **por expresión del workflow, no por el
modelo** — el prompt no se toca, y evita la contradicción interna del spec
(regla 7 contra el contrato de herramientas).

---

## 4. Fase 3 — el hallazgo importante

La Fase 3 propone descomponer el agente único en piezas:

```
clasificador → motor determinista de políticas → ejecutor → redactor → validador
```

El modelo deja de decidir y de llamar herramientas. El motor decide, el ejecutor
actúa, y el redactor **solo redacta con hechos que se le autorizan**.

### Lo que GPT no podía saber: esto arregla nuestros dos peores fallos

No es teoría. Los dos fallos más graves que hemos tenido **desaparecen por
diseño** en esa arquitectura:

**1. El encadenamiento de dos herramientas.** Es el fallo que dejaba mudo al bot
con la pregunta más común del negocio. Ocurre porque **el modelo llama a las
herramientas**. En la Fase 3 el modelo no llama a ninguna: las llama el ejecutor,
que es código. La clase entera de fallo deja de existir — y con ella la
dependencia del nodo de la comunidad y de su `thinkingEnabled`.

**2. El precio que no se re-consulta** (descubierto hoy, 9-ago). El agente
repitió 4.000 GYD de memoria con la tabla ya en 5.000. En la Fase 3 los precios
van en `facts_allowed_in_response`, inyectados en cada turno por el motor. El
redactor **no puede** tirar de memoria para una cifra, porque las cifras se las
dan hechas y el validador rechaza las que no vengan de ahí.

Y de rebote, el tercer fallo de hoy —el nodo mandando `<｜｜DSML｜｜tool_calls>`
como texto al cliente— lo caza el **validador determinista** de la fase 3F antes
de que salga.

> Esto es un argumento real y medido a favor de la Fase 3, y no estaba en el
> spec porque GPT no conocía ninguno de los tres fallos.

### Lo que la Fase 3 cuesta, y es mucho

**Coste por mensaje.** Hoy: **1 llamada al modelo**. Con la Fase 3 completa:
clasificador + redactor + (a veces) validador = **2 o 3**. Más latencia y más
gasto por cada mensaje, para siempre.

**Tamaño.** Nueve subfases (3A-3I), cada una con dataset, métricas, umbrales y
feature flags. Es varias veces la Fase 2, que a su vez era 3-5 veces la Fase 1.

**Toca lo único afinado a base de sangre.** El prompt actual funciona tras tres
roturas documentadas (`11-lenguaje-deliberativo-rompe-deepseek.md`). La Fase 3I
dice "no elimines el prompt antiguo hasta verificar que sus reglas fueron
migradas" — y son **23 secciones** de reglas, varias descubiertas por
incidentes reales.

### Dependencia dura que hay que ver

**La Fase 3 no se puede hacer sin la 2A.** Su propia entrada lo dice: el
clasificador en sombra recibe `operation_id` y `trusted_state`, y el motor de
políticas recibe `operation`. Sin estado canónico no hay nada que pasarles.

Cualquier intento de empezar por la 3 sin la 2A acaba reinventando la 2A peor.

---

## 5. Lo que el spec no ve — actualizado

`FASE2-ANALISIS.md` ya listaba cuatro omisiones (depósitos MMG, beneficiario
parcial, `Ultima cotizacion`, integración con la Fase 1). Siguen vigentes.
**Cuatro más, aparecidas desde entonces:**

| | Qué | Por qué importa |
|---|---|---|
| 5 | **`cerebro_servicios`** — combos, recargas, visa, traducción, México | La Fase 3 modela solo remesas. Cinco servicios más pasan por el mismo agente y no aparecen en ningún `intent` del clasificador |
| 6 | **La ventana de silencio y `ai_generated`** | El Decisor ya corta sin llamar al modelo. El motor de políticas de la 3C tendría que absorber esa lógica, no duplicarla |
| 7 | **La doble lectura de imágenes** | El spec trata la visión como un paso simple. Hoy son dos lecturas y un árbitro contra el libro de depósitos. La 3 no lo contempla |
| 8 | **La ventana de 24 h de WhatsApp** | El outbox de la 2E asume que un mensaje se puede reintentar. Fuera de la ventana **no se puede**, por muchos reintentos que haga |

La 8 es la más seria: **el outbox reintentando un mensaje fuera de la ventana de
24 h reintenta algo que nunca va a entregarse.** Hay que combinarlo con
plantillas de Meta o el outbox se llena de `failed` eternos.

---

## 6. Recomendación de orden

Por riesgo real mitigado, no por el orden del documento.

### Ahora

| | Qué | Por qué |
|---|---|---|
| **1** | **2A** — `remittance_operations` + `operation_id` + backfill | Cimiento de todo. Y con "sí hay dos remesas a la vez" confirmado, arregla un fallo real. Migrar ahora cuesta nada: son 8 deals |
| **2** | **2C** — beneficiarios | Aquí vive la deuda 14 (`registrar_beneficiario_zelle` contaminando otra operación). Agravada por lo mismo |

### Después, y solo entonces

| | Qué | Condición |
|---|---|---|
| 3 | **2E** — outbox | **Junto con las plantillas de Meta**, no antes (ver omisión 8) |
| 4 | **3A** — clasificador en sombra | Riesgo cero: no toca ni una respuesta. Pero necesita 2A para tener `operation_id` que clasificar |

### Lo que NO haría todavía, y lo digo claro

- **2F** (cortar `deals.notes` como fuente de verdad). Es el final del camino, no
  el principio. Mientras haya escritura dual, todo convive sin romper nada.
- **3C-3H completo** (motor, redactor, validador, routing, A/B). Es la
  arquitectura correcta y algún día será lo que toca — pero con el volumen de
  hoy es maquinaria muy por delante de la demanda, triplica el coste por mensaje
  y pone en juego lo único que funciona bien.
- **Fase 4 SaaS.** El propio spec dice que no.

### La excepción barata: hacer ahora lo que después es carísimo

**Poner `tenant_id` en las tablas nuevas de la Fase 2 desde el primer día.**

Hoy cuesta una columna con default. El día que haya una segunda empresa, añadirlo
significa migrar todas las tablas, todas las funciones y todas las consultas del
Cerebro. Es exactamente lo que pide la Fase 4 (*"no agregues configuraciones
globales nuevas que después impidan separar empresas"*) y sale gratis **solo si
se hace ahora**.

---

## 7. Cómo replantearía la Fase 3 cuando toque

No como está escrita. La versión cara son tres llamadas por mensaje; **casi todo
el beneficio se consigue con una sola pieza**:

> **El motor determinista (3C) sin clasificador y sin redactor nuevo.**

Es decir: que el estado y los hechos autorizados los calcule **código** y se
inyecten en el contexto del prompt actual, igual que ya se hace con
`cerebro_conversacion_no_vista()`. El agente sigue siendo uno, sigue siendo
DeepSeek, sigue con su prompt afinado — pero **deja de decidir cifras**.

Eso solo arregla el fallo del precio de hoy, no cuesta ni una llamada extra, y no
obliga a migrar 23 secciones de prompt. La descomposición completa se puede
seguir haciendo después, si el volumen la justifica.

**No es lo que dice el spec.** Lo escribo porque creo que es la versión que
compensa para este negocio, hoy.

---

## 8. Antes de escribir la primera línea de 2A

- [ ] Decidir la inyección de `operation_id` (recomendado: por expresión)
- [ ] Confirmar si los 4 hashes sin deal son el bug del hash o imágenes descartadas
- [ ] Decidir quién cierra los deals (12 en "Entregada" con `status='open'`)
- [ ] Confirmar que `tenant_id` entra desde el principio
- [ ] Decidir si `depositos_mmg` se enlaza (recomendado) o se absorbe
