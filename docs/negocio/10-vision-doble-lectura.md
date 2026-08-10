# Fotos giradas: dos lecturas y un árbitro

Desplegado en producción la noche del **8 al 9 de agosto de 2026**. Es un cambio
en el flujo del Cerebro, no solo texto.

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

Se revirtió entero.

---

## Lo que sí funciona

Leer la imagen **dos veces** —tal cual y girada 180— y **elegir con datos, no
con opiniones**:

```
Hash imagen
  → Vision A (imagen tal cual)
  → Recuperar imagen para girar
  → Girar 180
  → Vision B (imagen girada)
  → Preparar candidatos
  → ¿Cuál existe en el libro?     <-- el árbitro
  → Parsear vision (elige)
```

**Todo en línea, sin una sola bifurcación.** No es un capricho: el nodo de
visión no deja pasar la imagen ni el contexto, así que la correspondencia entre
imagen y resultado se mantiene **por posición**. Si alguien mete un `if` en
medio, esa correspondencia se rompe y un comprobante puede acabar registrado en
la conversación de otro cliente. **No bifurcar aquí.**

### El árbitro

Cuando las dos lecturas son igual de plausibles —las dos con 14 dígitos,
destinatario válido e importe razonable— y solo cambia un dígito, **ninguna
regla de forma puede decidir**. Se comprobó: puntuaban exactamente igual.

Así que se le pregunta al libro de depósitos: **¿cuál de las dos referencias
existe de verdad?** Eso no opina, comprueba.

1. Si una existe y la otra no → gana esa
2. Si no desempata → se puntúa la forma (longitud, destinatario, importe)
3. Si sigue empatado → gana la **original**: la mayoría llegan derechas

---

## Cómo se comportó en las pruebas

Con comprobantes reales entrando por WhatsApp:

**Foto boca abajo (52.000):**

```
A original →  10397588792360  →  no está en el libro
B girada   →  10397388792960  →  SÍ está
ELEGIDA: la girada.  "la referencia girada SI esta en el libro"
```

**Foto derecha (40.000):**

```
A original →  20397391101636  40.000  →  SÍ está en el libro
B girada   →  2039739101636    4.000  →  no está
ELEGIDA: la original.  "la referencia original SI esta en el libro"
```

Fíjese en la segunda: al girar una imagen que ya estaba derecha, el modelo leyó
**4.000 en vez de 40.000**. El mismo fallo que tuvo Héctor. El árbitro lo
rechazó.

---

## Lo que cuesta

**Una llamada de visión más por imagen.** Con lo que vale equivocarse en un
importe —50.000 GYD en un solo caso— sale barato.

---

## Auditoría

Cada comprobante guarda por qué se eligió lo que se eligió:

```sql
-- ¿cuántos se resolvieron gracias a la lectura girada?
SELECT id, value, notes FROM deals
 WHERE notes LIKE '%Ref:%' ORDER BY created_at DESC LIMIT 20;
```

En la ejecución de n8n, el nodo `Parsear vision` devuelve `leida_girada` y
`arbitro` con el motivo en texto.

---

## Reversión

`ROLLBACK-v2-antes-rotacion.json` es la copia previa a todo esto. Restaurarla
deja el flujo como estaba, conservando las mejoras del prompt de visión (los
tres formatos, la cuenta de dígitos, la doble comprobación del importe), que son
anteriores y siguen siendo útiles.

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
