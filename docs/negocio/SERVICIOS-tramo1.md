# Servicios informativos — tramo 1

Que el agente sepa responder cuando le preguntan por algo que no son remesas.
**Preparado, no desplegado.**

Sale del caso de Yoandris (592 608 2754): pidió un combo, el bot le dijo que
el negocio no los hacía, y Osmany acababa de decirle que sí. Venta perdida por
desconocimiento.

---

## Alcance — y lo que deliberadamente NO entra

**Entra:** que el agente conozca combos, recargas, visa, traducción y envío a
México; que responda con datos reales; y que ofrezca pasar con un operador
cuando no pueda cerrar él.

**No entra, a propósito:**

- **Ningún menú.** Ese listado A-G viene de un autoresponder y no se replica.
  El agente responde a lo que le preguntan, no recita un catálogo.
- **Ningún deal.** Los servicios no monetarios necesitan su propio pipeline y
  eso está pendiente de hablar con Osmany. Hasta entonces, el agente informa y
  deriva; no registra nada.
- **Cotizar combos.** Los precios cambian y el flujo no está diseñado.
- **Tocar el flujo de remesas.** Ni una línea.

---

## 1. Base de datos — ✅ ya aplicado

Tabla `cerebro_servicios` con cinco filas y la función `cerebro_servicio_get()`.
Nadie la lee todavía, así que no cambia ningún comportamiento.

Lo que guarda son **hechos, no respuestas enlatadas**: precios, condiciones y
límites que el agente usa para contestar con su estilo de siempre.

| clave | requiere_humano | por qué |
|---|---|---|
| `combos` | sí | Flujo sin diseñar. Informa, manda el catálogo, recoge qué y para dónde |
| `recargas` | sí | El precio depende de la promo de Etecsa. Solo el rango, nunca cerrado |
| `visa` | no | Precio fijo y formulario. El agente puede cerrarlo |
| `traduccion` | no | 4.000 GYD por hoja. Con más de dos hojas, a un operador |
| `mexico` | sí | Puede cotizar con `calcular_usd`, pero el registro no está automatizado |

Los textos los edita Osmany con un `UPDATE`, sin tocar n8n.

---

## 2. La herramienta nueva

Un nodo `postgresTool` en el Cerebro, colgando del agente como los demás.

**Nombre:** `consultar_servicio`

**Consulta:**

```sql
SELECT * FROM cerebro_servicio_get($1);
```

**Parámetro:** el nombre del servicio, que aporta el modelo. Vacío devuelve todos.

**Descripción de la herramienta** — esto es lo que lee el modelo para decidir
cuándo llamarla, así que importa tanto como el SQL:

> Devuelve la información oficial de un servicio del negocio que NO son remesas
> a Cuba: combos de comida, recargas telefónicas, extensión de visa, traducción
> de documentos, o envío de dinero a México. Llámala SIEMPRE que el cliente
> pregunte por alguno de ellos, pasándole el nombre del servicio. Sin parámetro
> devuelve todos. PROHIBIDO inventar precios, plazos o condiciones de estos
> servicios: usa únicamente lo que devuelva esta herramienta.

---

## 3. El cambio en el prompt — seis líneas

Es la parte delicada. El prompt son 33.000 caracteres afinados para remesas y
cualquier cosa que se añada compite por la atención del modelo. Por eso todo el
contenido vive en la tabla y aquí solo va la regla.

Se inserta como sección nueva, después de `## NEGOCIO`:

```
## OTROS SERVICIOS (no son remesas)
El negocio ofrece ademas: combos de comida a Cuba, recargas telefonicas,
extension de visa, traduccion de documentos y envio de dinero a Mexico.
Cuando el cliente pregunte por alguno, llama a consultar_servicio con el nombre
y respondele con lo que devuelva, en tu estilo de siempre: guiando y aclarando
dudas. NO recites una lista de servicios ni sueltes un menu, responde a lo que
te preguntan.
PROHIBIDO inventar precios, plazos o condiciones de estos servicios. Si la tool
no lo dice, no lo sabes: pregunta o pasa con un operador.
Si la tool indica que hace falta una persona, informa igual con lo que sepas y
OFRECE pasarlo con un operador. No llames a derivar_humano por tu cuenta: solo
si el cliente acepta.
El resto de reglas no cambia: de usted, sin emojis, una pregunta por mensaje.
```

**Lo de `derivar_humano` importa.** Esa herramienta corta la conversación y
deja al cliente esperando a una persona. Si el agente la llamara cada vez que
alguien pregunta por combos, acabarías con la bandeja llena de derivaciones.
Por eso: ofrecer, y derivar solo si el cliente dice que sí.

---

## 4. Cómo probarlo

Contra la conversación de pruebas, antes de que lo vea un cliente.

| | Se le dice | Debe pasar |
|---|---|---|
| 1 | *"Quiero mandar un combo de comida para Las Tunas"* | Reconoce el servicio, manda el catálogo, pregunta qué quiere. **No dice que no lo hacen** |
| 2 | *"¿Cuánto cuesta traducir un documento?"* | 4.000 GYD por hoja, directo, sin derivar |
| 3 | *"Tengo 5 hojas para traducir"* | No inventa el descuento: ofrece un operador |
| 4 | *"¿Hacen recargas?"* | Da el rango 5.200–6.200 y que depende de la promo. **Ningún precio cerrado** |
| 5 | *"Necesito extender la visa"* | Aclara que **no hacen el trámite**, solo suben la aplicación. 4.000 GYD y el formulario |
| 6 | *"Quiero mandar 20 mil a México"* | Cotiza con la tasa de 260 y ofrece un operador para registrarlo |
| 7 | **"¿A cómo está el cambio?"** | **Responde de remesas como siempre.** Ni menciona los otros servicios |
| 8 | **Flujo completo de remesa** | **Idéntico a hoy.** Es la prueba que decide |

Las dos últimas son las importantes. Lo nuevo no vale nada si degrada lo que ya
funciona, y el riesgo real de tocar el prompt es justo ese.

---

## 5. Reversión

- **La herramienta:** se desconecta del agente y deja de existir para él.
- **El prompt:** se quita la sección. Guardar el `systemMessage` actual antes
  de tocarlo.
- **La tabla:** se queda. No molesta a nadie.

---

## 6. Lo que sigue pendiente

- **Combos de verdad**, con cotización y pedido: esperando a lo que cuente
  Osmany.
- **Pipeline nuevo** para servicios no monetarios, con sus etapas.
- **México como servicio completo**, registrando la operación en el pipeline de
  remesas.
- **Limpiar el México legado:** el prompt de visión todavía acepta como destino
  válido una cuenta Albo que ya no existe. Es lógica antifraude apuntando a algo
  inventado.
