# El modelo narrando en voz alta, y el cliente en bucle

Dos controles deterministas desplegados el **10 de agosto de 2026**. Nacen del
mismo incidente y comparten la misma lección.

---

## 1. El razonamiento saliendo hacia el cliente

Cuatro respuestas salieron con el razonamiento del modelo pegado delante:

> *«El cliente dijo "Clasica tropical" pero no eligió claramente entre las dos.
> Necesito saber cuál de las dos quiere. Le pregunto.*
>
> *Perfecto. ¿En cuál de las dos: Clásica o Tropical?»*

**Tres clientes distintos, todas el mismo día.** No es un caso aislado.

### Lo que NO era la solución

**El prompt ya lo prohibía**, con estas dos líneas:

```
- PROHIBIDO narrar tus reglas, tu razonamiento o tu proceso.
  El cliente no debe enterarse de como funcionas por dentro.
- PROHIBIDO referirte al cliente en tercera persona.
```

El modelo las incumplió cuatro veces **con la prohibición delante**. Se valoró
reescribir el prompt y se descartó: añadir una quinta prohibición a un texto que
ya tiene dos idénticas no cambia nada. **No se tocó el prompt.**

> Es la lección del 10-ago repetida por tercera vez en un día: **si algo tiene
> que pasar sí o sí, no puede depender de que el modelo obedezca.**

### El control

Un filtro determinista en `Normalizar formato`, **antes** de la normalización de
párrafos. Si el primer párrafo es narración y detrás queda respuesta de verdad,
el primer párrafo se cae.

```js
/^(el (cliente|usuario)\b|parece que el (cliente|usuario)\b
  |(no debo|no puedo) (asumir|dar por)|voy a (preguntar|pedir)\b
  |debo (preguntar|pedir|confirmar)\b)/i
```

**Conservador a propósito:**

- solo mira el **primer párrafo**;
- solo corta si **queda respuesta detrás**;
- **nunca deja el mensaje vacío**.

Si el mensaje entero fuera razonamiento sin respuesta, no se toca: **preferimos
un mensaje raro a un silencio**, que es lo que dejó a clientes esperando 90 h.
Los cuatro casos reales tenían respuesta detrás.

Va **antes** de `normalizar()` y no dentro, porque ese nodo tiene un principio
innegociable —*solo inserta saltos, nunca reconstruye*— y una red de seguridad
que devuelve el original si el texto cambia. Cortar dentro la habría activado.

### Cómo se verificó

Verificado contra **los 275 mensajes que ha enviado el bot**: el patrón caza los
4 filtrados y **ni uno más**.

Y en un **banco de pruebas aparte dentro de n8n** —no en Node— con el código
exacto del nodo y 9 casos: las 3 fugas reales y 6 mensajes legítimos, incluidos
un párrafo largo que el normalizador debe partir y uno con la cifra `2.8`.
**9/9 correcto**, `2.8` intacto, contenido idéntico ignorando saltos.

> **Ojo al probar en Node en vez de en n8n:** las expresiones regulares pasan por
> JSON al subir el workflow y el escapado cambia. La prueba buena es dentro de
> n8n.

### La causa de fondo, que sigue ahí

**El propio prompt le da el material para deliberar.** Dos de las cuatro fugas
eran sobre la vía de depósito, y el modelo repetía casi literal la frase del
prompt:

| prompt | modelo |
|---|---|
| *«esto SÍ se pregunta SIEMPRE, **no se asume nunca**»* | *«**No debo asumir**. Le pido la vía.»* |

El mapeo plano de la vía con valor por defecto
(`15-la-via-de-deposito-por-defecto.md`) le quita el motivo de deliberar en esos
dos casos. El filtro cubre el resto.

---

## 2. El cliente en bucle

En la misma conversación el bot preguntó **tres veces** *«¿Clásica o Tropical?»*
El cliente respondió *«Clasica tropical»* las tres. Nadie rompió el ciclo hasta
que entró Osmany a mano: *«O es clásica o es Tropical»*.

**No es raro.** Medido sobre el histórico, un cliente real recibió la pregunta
de la vía de depósito **cinco veces**.

### Por qué no vale comparar el texto

**El modelo reformula la pregunta cada vez.** Las tres de ese día eran:

```
¿Y cómo quiere que reciba el dinero: en tarjeta Clásica o en Tropical?
¿En cuál de las dos: Clásica o Tropical?
¿la tarjeta es la Clásica o la Tropical?
```

Un detector por texto exacto —o por el principio del mensaje— **no caza ninguna**.
Se comprobó midiendo: el detector textual solo disparaba con el número de
pruebas.

### El control

El bot hace **solo dos preguntas de opción cerrada**: *app o agente* y
*Clásica o Tropical*. Se cuenta el **tema**, no el texto. Si repite la misma
**4 veces en una hora deslizante**, `Control de abuso` asigna la conversación a
una persona por SQL y manda aviso con `type: BUCLE`.

Se añadió al nodo que **ya derivaba por SQL** cuando había más de 30 eventos en
una hora, reutilizando su patrón. La regla de volumen queda intacta.

### Calibración, medida antes de elegir

Sobre 6 días de histórico real, con ventana deslizante de una hora:

| Umbral | Conversaciones que habrían disparado |
|---|---|
| **4** | **1** — exactamente el caso donde tuvo que entrar Osmany |
| 3 | 4 — tres clientes más donde la tercera pregunta aún era razonable |

> **Una trampa en la que caí al medir:** la primera consulta agrupaba por hora de
> reloj (`date_trunc`) y el caso real no aparecía, porque sus cuatro mensajes
> caían a caballo entre dos horas. Estuve a punto de concluir que la regla no
> servía. **La ventana tiene que ser deslizante, como en la consulta real.**

### Cómo se verificó

1. `PREPARE` de la consulta completa. Firma `{text}`, **sin cambios**: n8n pasa
   los parámetros por posición y cambiarlos rompería el nodo.
2. Detección contra 6 días de histórico, en solo lectura.
3. El camino de escritura, en un bloque `DO $$ … RAISE EXCEPTION … $$`: cuatro
   preguntas **redactadas distinto a propósito**, y la conversación quedó
   asignada al perfil de derivación. Revertido sin rastro.

### Efecto secundario que hay que conocer

**Una derivación del bot no caduca sola** — decisión deliberada de la migración
`056`: si el bot derivó fue porque no sabía seguir. Si esto salta, el chat espera
a una persona hasta que alguien lo atienda. **El vigilante de la `057` avisa a
los 15 minutos**, así que está cubierto, pero no es invisible.

---

## Reversión

| Control | Nodo | Copia |
|---|---|---|
| Filtro de razonamiento | `Normalizar formato` | `ROLLBACK-v2-antes-filtro-razonamiento.json` |
| Cortacircuitos de bucle | `Control de abuso` | `ROLLBACK-v2-antes-bucle-pregunta-cerrada.json` |

Los dos son cambios de parámetros, no estructurales: se aplican solos, sin ciclo
de desactivar/activar. Ninguno toca datos.

---

## Vigilancia

```sql
-- ¿se ha cortado algun razonamiento? (mirar la traza de n8n: razonamiento_quitado)
-- y por si el filtro se queda corto, buscar fugas que hayan salido igual:
SELECT created_at, content_text FROM messages
 WHERE ai_generated
   AND split_part(content_text, E'\n', 1) ~* '^\s*(el (cliente|usuario)\M|no debo asumir)'
 ORDER BY created_at DESC LIMIT 20;   -- debe dar 0 filas de aqui en adelante

-- ¿cuantas veces ha saltado el cortacircuitos de bucle?
SELECT c.id, ct.phone, c.updated_at
  FROM conversations c JOIN contacts ct ON ct.id=c.contact_id
 WHERE c.assigned_agent_id='377b0c8c-c025-46ff-8088-7a929080831e'
 ORDER BY c.updated_at DESC;
```

**Si el filtro deja pasar una fuga nueva**, el patrón se amplía en
`Normalizar formato`; los cuatro casos conocidos empezaban todos por
*«El cliente…»*.
