# El lenguaje deliberativo en el prompt rompe las conversaciones

**Esto ya había pasado dos veces antes (1 y 5 de agosto) y volvió a pasar el
9-ago.** Se documenta aquí para que no haya una cuarta.

---

## El síntoma

La conversación funciona en el primer mensaje y **falla en el siguiente**:

```
Agente Remesas — Bad request - please check your parameters
The `reasoning_content` in the thinking mode must be passed back to the API.
```

Y como el agente falla varias veces seguidas, el sistema **asigna la
conversación a un humano y se calla**. El cliente se queda esperando a una
persona.

---

## El mecanismo

**DeepSeek V4 activa el modo de pensamiento de forma adaptativa cuando ve
lenguaje deliberativo en el prompt.** Y cuando piensa **y además** llama a una
herramienta, la API exige que se le devuelva su `reasoning_content` en las
peticiones siguientes. La memoria de n8n no lo conserva → 400.

Por eso solo estalla **cuando hay una tool de por medio**. Con un saludo nunca.

**No es el modelo, no es n8n: es el lenguaje del prompt.**

---

## Historial

| Cuándo | Sección culpable |
|---|---|
| 1-ago | "LA DIRECCIÓN DE LA PREGUNTA MANDA", luego renombrada "QUÉ TOOL DE CÁLCULO USAR" |
| 5-ago | La misma idea, otra vez renombrada: "CUÁL DE LAS DOS" dentro de `## TOOLS DE CALCULO` |
| **9-ago** | **`## OTROS SERVICIOS`** — escrita por mí el 8-ago sin conocer este historial |

**El error de método que costó caro en agosto:** quitar solo una palabra
(*"piénsala"*) y **dejar la sección entera, renombrada**. El fallo volvió, se
concluyó que el prompt era inocente, y se cambió de modelo sin necesidad.
Renombrar no arregla nada: hay que quitar el lenguaje.

---

## Lo que lo dispara

Cualquier frase que le pida **decidir, valorar, comparar o interpretar** antes
de llamar una herramienta. Ejemplos reales que estallaron:

- *"Lo que decide la tool es lo que el cliente PREGUNTA, no la moneda que nombre"*
- *"Si la moneda que nombra contradice lo que pregunta, manda lo que pregunta"*
- *"mira qué pregunta"*
- *"Si la tool no lo dice, no lo sabes: preguntas o pasas con un operador"*
- *"informa igual con lo que sepas y OFRECE pasarlo con un operador"*
- *"respondele con lo que devuelva, en tu estilo de siempre: guiando y aclarando dudas"*

---

## La forma que SÍ funciona: mapeo plano

Nada de verbos que inviten a razonar. Palabra → herramienta:

```
- 'enviar', 'mandar', 'poner', 'depositar' + monto  -> calcular_envio
- 'que lleguen', 'que reciba'              + monto  -> calcular_inverso

- 'combo', 'comida', 'mandar comida'   -> consultar_servicio('combos')
- 'recarga', 'saldo', 'etecsa'         -> consultar_servicio('recargas')
- 'traducir', 'traduccion', 'hoja'     -> consultar_servicio('traduccion')
```

Las condiciones que quedan son **de consulta**, no de juicio: *"con
requiere_humano=true, el mensaje termina con X"*. Eso es una tabla, no un
razonamiento.

---

## Cómo se confirmó el 9-ago

Sin suponer nada, comparando las dos secciones del mismo prompt:

| Turno 1 usa… | Sección | Turno 2 |
|---|---|---|
| `consultar_tasas` | mapeo plano (arreglada el 5-ago) | ✅ pasa |
| `consultar_servicio` | prosa deliberativa | ❌ **falla** |

Cuatro fallos seguidos con servicios, cero con tasas. Tras reescribir la sección
de servicios como mapeo, la misma secuencia pasa:

```
Turno 1 → consultar_servicio → OK
Turno 2 → OK
```

Y las respuestas siguen siendo correctas: 4.000 GYD por hoja, 20.000 por cinco,
24 horas.

---

## La regla, para el futuro

> **Antes de tocar el prompt: si la frase que vas a escribir le pide al modelo
> que decida, valore, compare o interprete, y hay herramientas de por medio,
> reescríbela como una tabla de correspondencias.**

Y si el fallo reaparece: **la sección entera se sustituye, no se renombra ni se
suaviza.** Ya se intentó y no funciona.

---

## Nota sobre "arreglar" cambiando de modelo

En agosto se cambió de modelo creyendo que el problema era del proveedor. No lo
era. Antes de tocar el modelo, revisar qué se añadió al prompt: el fallo aparece
justo después de un cambio de texto, y siempre en la sección que introdujo
lenguaje deliberativo.


---

## Añadido la madrugada del 9-ago: quitar el lenguaje NO siempre basta

Reescribir `## OTROS SERVICIOS` como mapeo plano **arregló el caso de dos turnos
seguidos** — verificado. Pero horas después volvió a fallar al encadenar
`consultar_servicio` + `calcular_usd_desde_gyd` en el **mismo** turno.

Y se cometió el error del manual: al añadir el mapeo de México se escribió
*"20,000 GYD entre 260 son 76 dolares, no 77. Redondear arriba entrega mas de lo
que el cliente deposito."* Una justificación perfectamente razonable para una
persona, y exactamente lo que no hay que escribir. Se quitó… **y siguió
fallando**.

Conclusión provisional: el prompt no es lo único que lo activa. Falta mirar el
**texto que devuelven las tools** — `cerebro_servicios.hechos` es prosa larga y
entra en la conversación como resultado. La siguiente hipótesis a probar es
acortarlo.

**Lo que sí queda confirmado y no hay que volver a discutir:**

- Explicar el porqué en el prompt es lenguaje deliberativo. Aunque suene a buena
  escritura, aquí rompe.
- El truncado lo garantiza el `floor` del SQL. **No hay que convencer al modelo,
  hay que hacer que llame a la herramienta.**
- La sección que el agente obedece siempre es `## TOOLS DE CALCULO`. Una regla
  metida en el texto de una tabla solo se lee si además consulta esa tabla.
