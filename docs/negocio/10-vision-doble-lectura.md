# Fotos giradas: cuatro lecturas y un árbitro

Desplegado en producción la noche del **8 al 9 de agosto de 2026** con **dos**
lecturas, y ampliado a **cuatro** el **10 de agosto**. Es un cambio en el flujo
del Cerebro, no solo texto.

---

## El problema

Los comprobantes llegan casi siempre como **foto de la pantalla de otro
teléfono**, y muchas veces giradas — boca abajo o de lado. El cliente no se da
cuenta porque su galería se las endereza al mostrarlas.

Con una imagen girada, el modelo **acierta a medias y cada vez en un sitio
distinto**. Tres casos reales del mismo día:

| Cliente | Qué leyó mal |
|---|---|
| Carlos | Cuatro dígitos trastocados en la referencia |
| Alexei | Referencia truncada, 12 dígitos en vez de 14 |
| **Héctor** | **2.000 GYD donde ponía 52.000** |

El de Héctor iba camino de pagarse con 50.000 GYD de menos.

Y la misma foto, leída dos veces, dio **errores distintos**: una vez acertó la
referencia y falló el importe, la siguiente al revés. No es que el formato sea
difícil: es que leyendo del revés acierta o falla según le toque.

---

## Lo que NO funcionó, y por qué se descarta

**Preguntarle al modelo en qué ángulo está la imagen.** Parecía lo obvio:
detectar, enderezar, leer. Se montó y se probó:

| Imagen | Respondió | Resultado |
|---|---|---|
| Girada 180 | 180 ✅ | la leyó perfecta |
| Derecha | **180** ❌ | la puso boca abajo y rompió la lectura |
| Derecha | **270** ❌ | igual |

Se probó con `gpt-4o-mini` y con `gpt-4o`, y con un prompt que le daba palabras
ancla y le pedía responder 0 ante la duda. Siguió fallando.

**La lección:** estos modelos leen texto girado razonablemente bien, pero
**decir en qué ángulo está se les da mucho peor que leerlo**. Y el fallo es
asimétrico: acertar el caso raro no compensa romper el común.

Se revirtió entero. **No volver a intentarlo.**

---

## Lo que sí funciona

Leer la imagen **cuatro veces** —a 0°, 180°, 90° y 270°— y **elegir con datos,
no con opiniones**:

```
Hash imagen
  → Vision clasificar y extraer            (0°, la imagen tal cual)
  → Recuperar imagen para girar  → Girar 180 → Vision segunda lectura (girada)
  → Recuperar imagen para girar 90  → Girar 90  → Vision tercera lectura (90)
  → Recuperar imagen para girar 270 → Girar 270 → Vision cuarta lectura (270)
  → Preparar candidatos
  → ¿Cuál existe en el libro?     <-- el árbitro
  → Parsear vision (elige)
```

**Todo en línea, sin una sola bifurcación.** No es un capricho: el nodo de
visión no deja pasar la imagen ni el contexto, así que la correspondencia entre
imagen y resultado se mantiene **por posición**. Si alguien mete un `if` en
medio, esa correspondencia se rompe y un comprobante puede acabar registrado en
la conversación de otro cliente. **No bifurcar aquí.**

Cada `Recuperar imagen para girar …` vuelve a coger el binario original de
`Hash imagen` por posición. Se gira siempre **desde el original**, nunca en
cascada.

### El árbitro

Cuando dos lecturas son igual de plausibles —las dos con 14 dígitos,
destinatario válido e importe razonable— y solo cambia un dígito, **ninguna
regla de forma puede decidir**. Se comprobó: puntuaban exactamente igual.

Así que se le pregunta al libro de depósitos: **¿cuál de las referencias existe
de verdad?** Eso no opina, comprueba.

1. Si alguna existe en el libro → gana esa (a igualdad, la de mejor forma)
2. Si ninguna → se puntúa la forma (longitud, destinatario, importe, alertas)
3. Si sigue empatado → gana la **original**, luego 180, luego 90, luego 270

El orden de desempate sale de medir: la mayoría llegan derechas, luego boca
abajo, y de lado es lo más raro.

---

## Por qué dos lecturas no bastaban (10-ago)

El conjunto `{tal cual, 180}` **depende de cómo venga la foto**. Si el cliente
la manda girada 90 grados, las dos lecturas caen de lado y **ninguna queda
derecha**. El conjunto `{0, 90, 180, 270}` es el mismo mire como mire la foto,
así que el resultado deja de depender de cómo la tomó el cliente.

**Medido antes de construirlo**, sobre 9 comprobantes reales con la referencia
confirmada en el libro de depósitos:

| Cómo llega la foto | Dos lecturas | Cuatro lecturas |
|---|---|---|
| Derecha / como la tenga | 8/9 | 8/9 |
| **De lado** | **6/9** | **8/9** |

Con la foto derecha no mejora nada. **Todo el beneficio está en el caso de
lado**, que es justo el que no estaba cubierto.

**Y se comprobó lo único que podía hacer daño:** de las lecturas equivocadas que
producen los giros extra, **ninguna existía en el libro**, y las correctas sí.
Añadir candidatos da más oportunidades de acertar sin ensuciar la decisión.

Queda un residuo que esto no arregla: **1 de 9 falla en los cuatro giros**. Es
ruido de lectura, no orientación, y para eso está el plan B de coincidencia
aproximada (`06-cruce-aproximado.sql`).

### Un matiz que sorprendió, y conviene no olvidar

**La visión SÍ sabe leer texto de lado.** El comprobante girado del 10-ago se
leyó perfecto a 0° y a 270°. El problema nunca fue que no supiera leerlo: era
que con solo dos lecturas no se le daba la oportunidad de caer en una
orientación buena.

---

## Cómo se comportó en las pruebas

**Foto boca abajo (52.000), con dos lecturas:**

```
A original →  10397588792360  →  no está en el libro
B girada   →  10397388792960  →  SÍ está
ELEGIDA: la girada.  "la referencia girada SI esta en el libro"
```

**Foto derecha (40.000), con dos lecturas:**

```
A original →  20397391101636  40.000  →  SÍ está en el libro
B girada   →  2039739101636    4.000  →  no está
ELEGIDA: la original.
```

Fíjese en la segunda: al girar una imagen que ya estaba derecha, el modelo leyó
**4.000 en vez de 40.000**. El mismo fallo que tuvo Héctor. El árbitro lo
rechazó.

**Comprobante de lado (39.000), ya con los cuatro giros, en producción:**

```
0°  → 10397535426076   180° → 10397535426076
90° → 10397535426076   270° → 10397535426076
las cuatro en el libro → gana el giro 0
```

**Comprobante antiguo del 4-abr (30.000), los cuatro giros:** las cuatro
leyeron `20386475511192` y 30.000. El cruce lo mandó a `deposito_antiguo`, que
es lo correcto.

---

## Lo que cuesta

**Tres llamadas de visión más por imagen** (antes era una más). Medido en
producción: **~3,5 s por llamada**, unos **+6 s** en cada mensaje con imagen.
Una ejecución con comprobante pasó de 25 s a 31 s, de los cuales 12 son el
debounce.

Con lo que vale equivocarse en un importe —50.000 GYD en un solo caso— sale
barato. **Si algún día la latencia molesta**, la salida no es quitar giros a
ciegas: es hacer que las lecturas 3 y 4 solo ocurran cuando el árbitro no haya
encontrado ninguna referencia en el libro con las dos primeras.

---

## Auditoría

Cada comprobante guarda por qué se eligió lo que se eligió. En la ejecución de
n8n, el nodo `Parsear vision` devuelve:

- `giro_elegido` — 0, 90, 180 o 270
- `leida_girada` — verdadero si no ganó la original
- `arbitro` — el motivo en texto

```sql
-- ¿cuántos se resolvieron gracias a una lectura girada?
SELECT id, value, notes FROM deals
 WHERE notes LIKE '%Ref:%' ORDER BY created_at DESC LIMIT 20;
```

---

## Reversión

`ROLLBACK-v2-antes-cuatro-rotaciones.json` deja el flujo con **dos** lecturas,
como estaba hasta el 10-ago. `ROLLBACK-v2-antes-rotacion.json` es la copia
anterior a todo esto y lo deja sin rotación ninguna, conservando las mejoras del
prompt de visión (los tres formatos, la cuenta de dígitos, la doble
comprobación del importe), que son anteriores y siguen siendo útiles.

Al revertir a dos lecturas hay que devolver también `Preparar candidatos`,
`Cual existe en el libro` (vuelve a 2 parámetros) y `Parsear vision`, porque los
tres se generalizaron a N candidatos.

---

## Cómo se prueba esto sin tocar producción

Lo que funcionó el 10-ago y conviene repetir: **un workflow de n8n aparte**, con
webhook de ruta aleatoria, que solo baje la imagen, la gire y llame a visión con
el mismo prompt y la misma credencial. Se le pasan URLs de comprobantes reales
con la referencia verdadera sacada del libro, y devuelve qué leyó cada giro.
Cero contacto con el Cerebro. **Borrarlo al terminar.**

> **Ojo al probar reenviando una imagen por WhatsApp:** si el fichero es
> idéntico a uno anterior, el hash lo para en `Dedup comprobantes` y **no se
> ejercita el cruce**. Hace falta una foto distinta.

---

## Una trampa de n8n que costó una prueba en falso

**Al cambiar la ESTRUCTURA de un workflow activo por API, n8n sigue ejecutando
la versión que tiene cargada en memoria.** Los cambios de parámetros —el texto
de un prompt, una consulta— sí se aplican solos; añadir nodos y reconectar, no.

Pasó: se desplegó la cadena nueva, se probó, y la ejecución siguió el camino
viejo. Se dio por bueno un resultado que no correspondía al código desplegado.

**Después de tocar nodos o conexiones, siempre:**

```bash
curl -s -X POST "$B/api/v1/workflows/$ID/deactivate" -H "X-N8N-API-KEY: $K"
sleep 2
curl -s -X POST "$B/api/v1/workflows/$ID/activate"   -H "X-N8N-API-KEY: $K"
```

Y comprobar en la ejecución que los nodos nuevos aparecen, no solo que el
resultado parezca correcto.
