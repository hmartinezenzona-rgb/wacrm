# El modelo del agente NO debe pensar

Resuelto el **9 de agosto de 2026**. Es el cambio más importante del fin de
semana: sin esto, la pregunta más común de un cliente dejaba al bot mudo.

---

## El síntoma

```
Agente Remesas — Bad request
The `reasoning_content` in the thinking mode must be passed back to the API.
```

El cliente **no recibe nada**. Tras varios fallos, el sistema asigna la
conversación a una persona y se calla.

---

## Qué lo dispara — medido, no supuesto

**Dos llamadas a herramienta en el mismo turno.** Sin excepción.

| Herramientas en el turno | Resultado |
|---|---|
| Una | ✅ siempre funciona |
| **Dos** | ❌ **siempre falla**, sean las que sean |

Se revisó todo el histórico de ejecuciones: **antes del 9-ago, ninguna ejecución
con éxito usó dos herramientas.** Nunca. Y todas las de dos fallaron.

No se veía porque el bot suele llamar a una herramienta por turno. Salta en
cuanto el cliente pregunta dos cosas juntas:

> *"Buenos días, ¿a cómo está el cambio hoy? ¿Cuánto llega si envío 30 mil?"*

Que es, probablemente, **la pregunta más frecuente del negocio**.

---

## La causa

`deepseek-v4-flash` tiene pensamiento **adaptativo**. Cuando piensa y encadena
dos llamadas a herramienta, la API exige que se le devuelva su
`reasoning_content` en la segunda. **El nodo oficial de n8n no lo conserva.**

n8n lo tiene abierto como incidencia interna (`AI-2422`) y **no ofrece ninguna
forma de desactivar el pensamiento**. No hay opción escondida: se comprobó.

---

## Lo que NO funcionó

**`deepseek-chat`** — era la variante sin pensamiento, pero **DeepSeek la retiró
el 24-jul-2026** junto con `deepseek-reasoner`. La documentación del nodo de n8n
todavía la recomienda: **está desfasada**. Se llegó a desplegar y hubo que
revertir de urgencia.

**GPT-5.3 (`gpt-5.3-chat-latest`)** — peor que el problema:

- Rechaza el parámetro `temperature`, que había que quitar (perdiendo el 0.3 con
  el que está afinado el bot).
- Y sobre todo: **no llamó a ninguna herramienta**. Contestó *"por 30,000 GYD
  llegan 60,000 CUP"* usando una tasa de hace un mes. Lo correcto eran 84.000.

> **Un bot mudo es un problema. Un bot que se inventa precios con seguridad es un
> peligro.** El prompt está afinado para DeepSeek, y buena parte de esa afinación
> es lo que le obliga a usar las herramientas. Cambiar de modelo **no es cambiar
> un cable**: hay que reafinar el prompt entero.

---

## La solución que SÍ funciona

Nodo de la comunidad **`n8n-nodes-deepseek-chat-model`** (Jay Nguyen,
`nguyenthieutoan` — el mismo que sigue el problema en el foro de n8n).

Su aportación es exponer el interruptor que el oficial no tiene.

### Cómo quedó configurado

```
Nodo:  "DeepSeek sin pensamiento"
tipo:  n8n-nodes-deepseek-chat-model.lmChatDeepSeek
  model ............ deepseek-v4-flash     (el mismo de siempre)
  thinkingEnabled .. false                 <- ESTO es lo que arregla el fallo
  options .......... {"temperature": 0.3}  (el mismo de siempre)
credencial: deepseekApi id 2joB4BwDAiyuSMcC ("deekpseek comunidad")
```

**Solo cambió una cosa: el modelo ya no piensa.** Mismo modelo, misma
temperatura, mismo prompt, mismas herramientas. El tono es indistinguible.

### Verificado

```
Herramientas en el turno:  calcular_inverso + consultar_tasas  (dos)
Estado:                    success
30,000 GYD  -> 84,000 CUP          correcto
100,000 CUP -> depositar 35,720 GYD (redondea al alza: recibe al menos lo pedido)
Tasa: 2.8                          correcto
```

---

## Detalles que hay que saber

**Es un nodo de terceros.** Solo funciona en n8n autoalojado. Se instala desde
Settings → Community Nodes y **reinicia n8n**.

**Su credencial es distinta** (`deepseekApi`, minúscula) de la del nodo oficial
(`deepSeekApi`). No se hereda: hay que crearla desde el nodo nuevo.

**El nodo oficial "DeepSeek Chat" sigue en el lienzo, desconectado.** Volver
atrás es mover un cable — pero volver atrás **reintroduce el fallo**.

**Si algún día n8n arregla `AI-2422`**, conviene volver al nodo oficial y dejar
de depender de un tercero. Comprobar entonces que el turno de dos herramientas
sigue funcionando antes de dar el cambio por bueno.

---

## El precio de depender del nodo de la comunidad — visto el 9-ago

**El nodo a veces no intercepta la llamada a herramienta y la manda al cliente
como texto.** Ocurrió una vez, en la conversación de pruebas:

```
<｜｜DSML｜｜tool_calls>
<｜｜DSML｜｜invoke name="consultar_servicio">
<｜｜DSML｜｜parameter name="servicio" string="true">traduccion</｜｜DSML｜｜parameter>
</｜｜DSML｜｜invoke>
```

El modelo emitió el tool call en su formato interno (DSML) **como contenido**, el
nodo no lo reconoció, y el texto salió tal cual hacia WhatsApp con estado
`delivered`. La ejecución fue `success`: para n8n no pasó nada.

**Frecuencia medida:** se buscó el patrón en **todo el histórico de `messages`** y
aparece **una sola vez**, en la conversación de pruebas. **Ningún cliente lo ha
recibido.** Al repetir el mismo mensaje, respondió bien.

**Por qué importa igual:** es intermitente y silencioso. No lo detecta ninguna
alarma —la ejecución es correcta— y el cliente recibiría un churro
incomprensible en mitad de una cotización.

**Cómo vigilarlo:**

```sql
SELECT created_at, conversation_id, left(content_text,80)
  FROM messages
 WHERE sender_type='agent'
   AND (content_text LIKE '%DSML%' OR content_text LIKE '%tool_calls%')
 ORDER BY created_at DESC;
```

**Si empieza a repetirse**, lo que lo cierra de verdad es un filtro antes de
`Responder por WaCRM`: si el texto contiene `DSML` o `tool_calls`, no se manda —
se trata como fallo del agente y entra en el reintento que ya existe. Es
preferible que el cliente espere unos segundos a que reciba eso.

Es el coste de depender de un paquete de un tercero, y **no cambia la decisión**:
el nodo oficial rompe la conversación entera en cuanto hay dos herramientas, que
es mucho peor y mucho más frecuente.

---

## El parámetro, por si algún día hay que hacerlo a mano

Desde el 24-jul-2026 el pensamiento se controla en el cuerpo de la petición:

```json
{"thinking": {"type": "disabled"}}
```

Con el SDK de OpenAI va dentro de `extra_body`. Hay tres modos: sin
pensamiento, alto y máximo. Eso es exactamente lo que hace el nodo de la
comunidad, y lo que haría un nodo propio si alguna vez se construye.

---

## Relación con el otro documento

`11-lenguaje-deliberativo-rompe-deepseek.md` decía que el lenguaje deliberativo
en el prompt activaba el pensamiento. **Sigue siendo buena práctica escribir
mapeos planos** —el prompt quedó más claro— pero con el pensamiento apagado ya
no es lo que decide si la conversación se rompe. La causa real era el
encadenamiento de dos herramientas.
