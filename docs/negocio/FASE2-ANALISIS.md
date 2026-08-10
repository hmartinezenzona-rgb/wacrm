# Fase 2 — Análisis previo

Documento de análisis, **no de implementación**. Nada se ha tocado.
Contrastado contra la instancia real el 2026-08-07.

---

## 1. Veredicto general

**El spec es arquitectónicamente correcto.** El diagnóstico de dependencias es acertado y el modelo de dominio que propone es el que corresponde a un sistema financiero. No hay nada conceptualmente equivocado.

Los problemas están en otro sitio: **omite cuatro dependencias reales** de tu sistema que GPT no podía ver, **contiene una contradicción interna** entre dos de sus propias reglas, y su tamaño es de 3 a 5 veces la Fase 1, así que ejecutarlo de una sola vez es imprudente.

---

## 2. Dependencias verificadas en el sistema real

Todas confirmadas leyendo el SQL desplegado.

### 2.1 `ORDER BY created_at DESC LIMIT 1`

Siete lugares seleccionan la operación por "la más reciente":

| Dónde | Qué decide mal |
|---|---|
| `gestionar_beneficiario` | A qué envío pega el beneficiario |
| `Registrar beneficiario auto` | Ídem, en la ruta automática |
| `Registrar deposito auto` | A qué envío suma el depósito |
| `registrar_beneficiario_zelle` | A qué envío pega la cuenta Zelle |
| `marcar_destino_usd` | A qué envío marca la entrega en dólares |
| `registrar_reparto_multiple` | A qué envío pega el reparto |
| `Historial contacto` (CTE `abierto`) | Qué estado se le cuenta al cliente |

### 2.2 `deals.notes` como fuente de verdad

El estado canónico se **reconstruye parseando texto libre**:

- `LIKE '%BENEFICIARIO%'` → ¿ya hay beneficiario?
- `LIKE '%DEPOSITO%'` → ¿ya hay depósito? (decide si **suma** o **reemplaza** el importe)
- `LIKE '%CORREGIDO%'` → invalida el historial
- `LIKE '%Tarjeta: X\nCelular: Y%'` → detección de idempotencia por comparación de cadenas
- `LIKE '%ENTREGA EN USD: Clasica%'` → vía de entrega
- `regexp_matches(bloque, 'Tarjeta: ([0-9]{16})[^0-9]{0,20}Celular: ([0-9]{7,8})')` → beneficiarios del historial
- `substring(d.notes from '"banco_destino": *"([^"]*)"')` → cuenta habitual

Un operador que edite las notas a mano puede alterar el comportamiento del bot.

### 2.3 `conversation_id` como identificador de remesa

`WHERE d.conversation_id = $1 AND d.status='open' AND d.stage_id IN (...)`. Una conversación es un hilo de WhatsApp perpetuo; una remesa es un evento acotado. La equivalencia se rompe en cuanto hay dos operaciones vivas.

### 2.4 Hash sin transacción

`Dedup comprobantes` inserta en `comprobantes_hashes` justo tras la visión, mucho antes de que el depósito se registre. **Es el riesgo abierto más grave** y el spec lo aborda bien.

---

## 3. Lo que el spec NO ve

GPT solo tuvo dos ficheros. Estas cuatro piezas son reales y ninguna aparece en el spec.

### 3.1 `depositos_mmg` y el cruce automático — **la omisión más grave**

Existe una tabla con **319 filas, 236 ya consumidas**, y el nodo `Cruzar deposito con MMG` que casa el TransID del comprobante contra el correo del banco y escribe `deal_id` y `consumido_en` en ella.

Eso **es** el `remittance_verifications` que el spec pide crear desde cero, pero ya existe, en producción, con datos. Cualquier modelo con `operation_id` tiene que adueñarse de esa relación (`depositos_mmg.deal_id` → `operation_id`), y el spec ni la menciona.

### 3.2 `cerebro_beneficiario_parcial`

El acumulador que junta tarjeta y celular llegados en mensajes distintos, con ventana de 24 h e invalidación por corrección. Es exactamente el `known_fields` / `pending_confirmation` del "estado de conversación" que el spec pide diseñar — ya implementado, con otra forma. Hay que mapearlo, no reinventarlo.

### 3.3 `Ultima cotizacion` — regex sobre los mensajes del propio bot

El nodo recupera la cotización vigente con:

```sql
content_text ~ '\*[0-9][0-9,\.]* (GYD|MXN|USD)\*'
```

sobre los mensajes que el agente ya envió. Es el caso más puro de "expresiones regulares para reconstruir operaciones" que el propio spec quiere eliminar, y `remittance_quotes` lo resuelve — pero el spec no sabe que esta dependencia existe ni que alimenta la comparación "monto distinto al cotizado".

### 3.4 Integración con la Fase 1

El outbox choca directamente con lo que acabo de construir:

- `Cerrar lote` cierra el lote cuando la ruta termina. Con outbox, el criterio pasa a ser "la respuesta está guardada en outbox", que es **otro punto** del flujo.
- La ruta `SKIP` (`Respuesta valida?` → `SKIP - no responder`) **no debe** generar fila de outbox. El spec dice "o la ruta determinista termina en silencio autorizado", pero no distingue los seis silencios distintos que tiene el Cerebro.
- `cerebro_ejecuciones` y el `execution_id` ya dan trazabilidad; `tool_execution_log` debe colgar de ahí en vez de duplicarla.

---

## 4. Contradicción interna del spec

La regla 7 dice **"no cambies el prompt"**. Pero el contrato de herramientas exige que cada llamada reciba:

```json
{"operation_id": "...", "idempotency_key": "...", "expected_operation_version": 1}
```

Si esos parámetros los tuviera que producir el modelo, habría que documentárselos en el prompt — violando la regla 7. Y sería mala idea: un LLM inventando claves de idempotencia es justo lo que no quieres.

**Salida limpia:** los tres campos los inyecta el *workflow*, no el modelo. En n8n, un `postgresTool` puede recibir parámetros por expresión fija en vez de por `$fromAI`. El `operation_id` lo resuelve el `Decisor` y se inyecta; la `idempotency_key` se deriva de `execution_id + nombre de tool + hash de argumentos`; la `version` se lee de la operación. **El prompt no cambia ni una línea y el modelo sigue viendo las mismas herramientas.**

Esto hay que decidirlo antes de escribir nada, porque condiciona todo el diseño de la capa de herramientas.

---

## 5. Realidad de escala (dato importante)

| Métrica | Valor |
|---|---|
| Deals totales en el pipeline | **8** |
| Antigüedad | Todos de los últimos 7 días |
| Conversaciones | 25 |
| Mensajes últimos 7 días | 507 |
| Depósitos MMG | 319 (236 cruzados) |
| Hashes de comprobante | 11 |

El sistema lleva en producción desde el **5 de agosto**. Esto tiene dos lecturas, y las dos importan:

- **A favor de hacerlo ya:** migrar 8 deals es trivial. Dentro de seis meses con miles de operaciones, la misma migración es un proyecto en sí misma. El coste de la Fase 2 es casi todo construcción y pruebas, casi nada migración de datos. **Es el mejor momento posible.**
- **En contra de hacerlo entero:** un modelo de 9 tablas para un sistema con 8 deals es mucha maquinaria por delante de la demanda. Conviene por partes, priorizando por riesgo real y no por completitud del diseño.

---

## 6. Problemas de integridad que ya existen hoy

Encontrados al medir, no estaban en ningún spec:

1. **Deals en "Entregada" con `status='open'`.** 7 de 8. Nadie los cierra. No rompe nada hoy porque las consultas filtran por etapa, pero significa que `status` no es fiable como señal.
2. **2 de 8 deals entregados no tienen bloque `BENEFICIARIO`.** El registro canónico ya está incompleto: se entregó dinero y el sistema no sabe a quién. El operador lo resolvió por fuera.
3. **11 hashes frente a 8 deals; 4 hashes sin ningún deal creado en ±10 minutos.** Compatible con el fallo del hash sin transacción, aunque también podrían ser imágenes clasificadas como comprobante que nunca llegaron a deal. **Merece una comprobación dirigida antes de afirmarlo** — si se confirma, es evidencia de que el bug ya disparó en producción.
4. **83 de 319 depósitos MMG sin consumir.** Puede ser normal (depósitos ajenos al bot) o cruces fallidos. Sin medir.

---

## 7. Secuencia recomendada

Partir la Fase 2 en seis tramos, cada uno desplegable y reversible por separado. Ordenados por riesgo mitigado, no por el orden del spec.

| | Tramo | Qué entrega | Por qué ahí |
|---|---|---|---|
| **2A** | `remittance_operations` + resolución de `operation_id` + backfill de los 8 deals + escritura dual | Sin cambio de comportamiento visible | Es el cimiento. Todo lo demás cuelga de aquí |
| **2B** | Depósitos + **hash transaccional** | Cierra el riesgo abierto más grave | **Se puede hacer solo, sin el resto.** Máximo valor por unidad de esfuerzo |
| **2C** | Beneficiarios + auditoría de correcciones | Elimina el parseo de notas para beneficiario | Aquí muere el regex de `Historial contacto` |
| **2D** | Capa de herramientas + idempotencia | Contratos, validación, sin SQL crudo del agente | Depende de 2A |
| **2E** | Outbox | Reintento de envío sin volver a llamar al modelo | Toca `Cerrar lote` de la Fase 1: cuidado |
| **2F** | Renderizador de notas + corte de la fuente de verdad | `deals.notes` pasa a ser vista | Último: hasta aquí, todo convive |

**Si hubiera que elegir una sola cosa: 2B.** Es el bug que hoy le dice a un cliente *"esa imagen ya estaba registrada"* por un depósito que nunca se procesó, y la Fase 1 amplió su ventana al hacer que los reintentos funcionen de verdad.

---

## 8. Preguntas a resolver antes de empezar

1. **¿Un cliente abre de verdad dos remesas a la vez?** Hoy: **cero casos** observados. Si en la práctica nunca pasa, la rama "pide aclaración o deriva" es complejidad especulativa. Si pasa una vez al mes y hoy se mezcla en silencio, es crítica. **Es una pregunta de negocio, no técnica.**
2. **¿Quién cierra los deals?** Si nadie, ¿el estado `completed` de la operación lo pone el operador al arrastrar a Entregada, o hace falta un paso nuevo?
3. **¿`depositos_mmg` se absorbe o se enlaza?** Recomiendo enlazar: tiene 319 filas y un flujo de ingesta propio que funciona.
4. **¿Dónde viven los feature flags?** `cerebro_config` ya existe desde el punto 10 de la Fase 1 y encaja sin crear nada.
5. **¿Hay que preservar historial en la migración?** Con 8 deals se puede reconstruir todo parseando las notas una única vez, o dejar las operaciones antiguas sin migrar y empezar limpio. Lo segundo es más barato y más honesto.

---

## 9. Riesgos de ejecución

| Riesgo | Comentario |
|---|---|
| **La escritura dual desincroniza** | Durante 2A-2F conviven notas y tablas. Hace falta una consulta de conciliación que detecte divergencias, corriendo en cada despliegue |
| **El outbox rompe el cierre de lote** | `Cerrar lote` es de la Fase 1 y funciona. Tocarlo requiere repetir las pruebas A-G completas |
| **Resolver `operation_id` mal es peor que no tenerlo** | Hoy "el más reciente" acierta casi siempre porque casi nunca hay dos. Un resolutor con un bug puede acertar menos que el heurístico actual |
| **Volumen bajo esconde fallos** | 8 deals no ejercitan los casos límite. Las pruebas tendrán que fabricar los escenarios, como en la Fase 1 |
| **Alcance** | 9 tablas, ~20 funciones, capa de herramientas, outbox, renderizador y migración. **Tres a cinco veces la Fase 1** |

---

## 10. Lo que hay que verificar en cuanto se arranque

Antes de escribir una línea:

- [ ] Comprobar si los 4 hashes sin deal son el bug del hash o imágenes descartadas
- [ ] Medir si los 83 depósitos MMG sin consumir son normales o cruces fallidos
- [ ] Confirmar con el negocio si existen remesas simultáneas
- [ ] Decidir el mecanismo de inyección de `operation_id` en las tools (sección 4)
- [ ] Releer `Cerrar lote` y las 9 rutas terminales antes de tocar el outbox
