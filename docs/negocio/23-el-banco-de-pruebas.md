# El banco de pruebas del Cerebro

**10 de agosto de 2026.** Petición de Humberto, con estas palabras: *«crea un
ambiente de prueba para ese tipo de cambios; solo cuando las pruebas pasen es
que se lleva a producción»*.

Está en **`pruebas/`**, y desde ahora **ningún cambio de un nodo Code del Cerebro
se despliega a mano**.

---

## Por qué hacía falta

La jornada del 10-ago dejó cuatro fallos que **pasaron todas las comprobaciones
previas** y solo aparecieron en producción:

| Fallo | Qué lo escondía |
|---|---|
| `Contexto conversacion` rota, 27 min sin Cerebro | `PREPARE` validó una versión **distinta** de la desplegada |
| El bot prometía la transferencia igual | dos notas del contexto se contradecían |
| La rama de Zelle no existía en la práctica | la condición la hacía inalcanzable |
| `SKIP` enviado a un cliente | el chequeo miraba el texto **antes** de limpiarlo |

Ninguno era un fallo de razonamiento. Los cuatro eran **la diferencia entre lo
que creí que había desplegado y lo que había**.

---

## Cómo se usa

```bash
cd ~/cerebro-fase1/pruebas

python3 banco.py --nodo "Normalizar formato" \
                 --candidato candidato-normalizar-formato.js \
                 --casos casos-normalizar-formato.json

# solo si sale VERDE:
python3 banco.py ... --desplegar
```

`--desplegar` **se niega a subir nada si algo falla**, y antes de tocar guarda
una copia `ROLLBACK-v2-antes-<nodo>.json`.

---

## Qué comprueba

**1. Una batería de casos** con su salida esperada escrita a mano
(`casos-*.json`). Hoy son 12 para `Normalizar formato`: el `SKIP`, el
razonamiento con y sin respuesta detrás, los bloques de datos, la pregunta
final, y una cifra decimal que no se puede partir.

**2. El histórico completo.** Los **371 mensajes reales** que ha enviado el bot,
pasados por la versión de producción **y** por la candidata, comparados uno a
uno. No es una muestra: son todos.

Y sobre cada diferencia, lo que puede hacer daño de verdad:

| Comprobación | Por qué |
|---|---|
| **Ningún dígito alterado** | `2.8 CUP` partido en dos líneas es dinero mal leído por el cliente |
| **Contenido idéntico** | el normalizador solo puede insertar saltos, jamás reescribir |
| **Bloques de datos intactos** | `*Titular:* / *Cuenta MMG:*` llevan saltos simples **a propósito** |

---

## Las tres decisiones de diseño

**1. Baja el código de producción por API.** No se prueba una copia pegada a
mano: se compara el nodo real contra el fichero candidato, y ese mismo fichero
es el que sube. Es exactamente lo que falló el 10-ago por la mañana.

**2. Corre dentro de n8n.** El comparador se despliega como workflow temporal y
se ejecuta allí. Probarlo con el Node del portátil demostraría que funciona en
**otro** motor de JavaScript, no en el que atiende a los clientes.

**3. El banco temporal se borra solo**, pase lo que pase (`finally`). No deja
basura en la instancia, que ya tiene 100 workflows y muchos son restos.

---

## El banco encontró un fallo en el banco

En su primerísima ejecución dio **dos casos en rojo**. El candidato estaba bien:
el error era del propio banco, que recortaba el código en `normalizar()` y
dejaba fuera `quitarRazonamiento()`. Probaba **media función**.

Si la batería no hubiera llevado casos de razonamiento, el banco habría dado
verde probando la mitad — y habría dado por buenos cambios que rompen el filtro
que impide que el razonamiento del modelo llegue al cliente.

> **Por eso la batería importa más que el histórico.** El histórico dice *«no he
> roto nada de lo que ya pasaba»*. La batería dice *«hace lo que tiene que
> hacer»*, y es la única que detecta que estás probando lo que no es.

Queda escrito en el propio `banco.py`, en el comentario de `solo_normalizar()`,
para que nadie lo vuelva a recortar.

---

## Su primer trabajo de verdad

El umbral del normalizador: se retiraba ante cualquier mensaje de menos de 110
caracteres, y por eso salían pegadas respuestas como

```
Por *30,000 GYD* llegan *90,000 CUP* a Cuba. ¿Desde dónde va a depositar, desde la app o con un agente?
```

Resultado del banco: **12/12 casos, 31 mensajes mejoran, 0 dígitos alterados, 0
contenido alterado, 0 bloques tocados.** Desplegado por el propio banco, y
confirmado en vivo con un mensaje real. Ver `20-el-normalizador-y-sus-tres-huecos.md`.

---

## Lo que NO cubre

- **Solo nodos Code.** El `Decisor` sí entra; el `Agente Remesas` (prompt), no.
  Para el prompt no hay banco posible: lo que valida un cambio de prompt es
  **mandar un mensaje real**. Los **nodos Postgres** tienen desde el 13-ago su
  propio banco, `banco-sql.py` — ver abajo.
- **No prueba la tubería entera.** Que un nodo esté bien no dice que esté
  conectado donde toca — el `SKIP` es justo eso: cada nodo hacía su trabajo
  correctamente y el orden estaba mal. Para eso, un mensaje al número de
  pruebas y leer la ejecución.

> **La regla sigue en pie:** el banco en verde **no** es una prueba de que
> funciona. Es una prueba de que no has roto lo que ya funcionaba. Lo demás lo
> demuestra un mensaje de verdad.

---

## `banco-sql.py` — el hermano para los nodos Postgres

**13 de agosto de 2026.** Los nodos Code tenían red desde el 10-ago; los
Postgres, que son los que mueven el dinero, no. Este los cubre.

```bash
cd ~/cerebro-fase1/pruebas

python3 banco-sql.py --buscar "<texto exacto>" --reemplazar "<texto nuevo>"

# solo si sale VERDE:
python3 banco-sql.py --buscar ... --reemplazar ... \
                     --etiqueta <nombre> --desplegar
```

Aplica un **reemplazo de texto exacto** sobre las queries, bajadas del JSON de
producción por API y parcheadas **por programa** — nunca retecleadas, que es lo
que costó 27 minutos el 10-ago.

**Cómo valida:** monta un workflow temporal en n8n (se borra solo, `finally`) con
un nodo Postgres por query, y ejecuta:

```sql
DEALLOCATE ALL;
PREPARE prod_vN AS <query de produccion>;
PREPARE cand_vN AS <query candidata>;
SELECT ... FROM pg_prepared_statements ...
```

`PREPARE` compila, planifica y comprueba tipos **sin ejecutar el cuerpo**: ni un
`INSERT`, ni un `UPDATE`. Y compara `parameter_types` de las dos versiones,
porque n8n pasa los parámetros **por posición**: si la firma cambia, la tool se
rompe aunque el SQL sea válido.

Verde = **todas** las queries compilan **y** ninguna firma cambia. En rojo no
despliega. `--desplegar` guarda `ROLLBACK-v2-antes-<etiqueta>.json`, sube, hace
el ciclo desactivar/activar y **relee lo desplegado para compararlo byte a byte
con lo validado**.

> **Ojo con el filtro de nodos, que ya falló una vez:** las tools del agente son
> `n8n-nodes-base.postgresTool`, no `n8n-nodes-base.postgres`. En su primera
> ejecución el banco encontró **2 de 6** nodos y habría validado dos mientras se
> desplegaban seis. Están los dos tipos en `TIPOS_PG`.

**Lo que sigue sin cubrir:** `PREPARE` dice que la query es válida, no que haga
lo correcto. Para eso, un bloque `DO` que fabrica el caso, lo mide y termina en
`RAISE EXCEPTION` para revertirlo — así se comprobó que meter `incident` en
`cerebro_resolver_operacion` arregla el caso de la incidencia sola (`ninguna` →
`unica`) y convierte en `ambigua` la incidencia vieja que convive con un envío
nuevo. Y después, la regla de siempre: **un mensaje real**.
