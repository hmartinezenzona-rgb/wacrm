# El normalizador de formato

**Desplegado el 9-ago-2026.** Nodo `Normalizar formato` en `Cerebro v2`, entre
`Respuesta valida?` y `Responder por WaCRM`.

Copia previa: `ROLLBACK-v2-antes-normalizador.json`.

---

## El problema, medido

Humberto: *"a veces no organiza bien las palabras, son textos amontonados y se
lee raro"*. Al medirlo sobre 153 mensajes del agente:

| | |
|---|---|
| Largo medio | **190 caracteres** — corto y correcto |
| Sin **ningún** salto de línea | **63 (41%)** |

**El agente no escribe mal ni largo. Escribe corto y sin separar.** Cuando un
mensaje de tres frases va en un bloque, en WhatsApp hay que releerlo.

Y el modelo **sabe** hacerlo: los mensajes de la visa o la promoción salieron
bien formateados. Es inconsistencia, no incapacidad. Por eso se arregla con
formato y no con prompt.

---

## Lo que hace

Determinista, sin IA, sin coste ni latencia extra:

1. Si el texto **ya tiene saltos**, no lo toca
2. Si mide **menos de 110 caracteres**, no lo toca
3. Separa el **saludo de apertura** (español e inglés)
4. Separa la **pregunta final**
5. Parte el cuerpo largo en un punto de frase pasada la mitad

---

## LOS DOS FALLOS QUE COSTÓ LLEGAR AQUÍ

Ambos salieron **probando con mensajes reales que llevaban cifras**. Ninguno se
habría visto revisando el código.

### 1. Partió una tasa por la mitad

```
ANTES:   Hoy la tasa está en *2.8 CUP* por cada GYD.
DESPUES: Hoy la tasa está en *2.
         8 CUP* por cada GYD.
```

El punto decimal leído como fin de frase. En un negocio de dinero, el cliente
lee otra cifra.

**Guardia:** el punto no cuenta como fin de frase si le sigue un dígito.

### 2. Se comió media frase — y esto cambió el diseño

```
ANTES:   ...llegan *84,000 CUP* a Cuba. La tasa de hoy es 1 GYD = *2.8 CUP*. Para que...
DESPUES: ...llegan *84,000 CUP* a Cuba. 8 CUP*.
```

La causa era de fondo: **troceaba el texto en frases y volvía a unirlas**, así
que todo lo que no casara con el patrón **se perdía**.

> ### La regla que sale de aquí
>
> **Solo INSERTAR saltos. Nunca reconstruir el texto.**
>
> Y una red de seguridad al final: si el texto sin espacios no es **idéntico**
> al original, se devuelve **el original sin tocar**. Mejor mal formateado que
> incompleto.

---

## Verificado

Sobre 9 mensajes reales de contextos distintos —confirmar depósito, negar una
rebaja, cotizar, pedir beneficiario, horarios, **inglés**, y uno que ya venía
formateado—:

**8 reformateados, 0 con contenido alterado, y el ya formateado intacto.**

Dos huecos que aparecieron al ampliar contextos:

- **El inglés no se tocaba** (buscaba `¿` y saludos en español). El bot atiende
  en inglés a algún cliente. Añadidos saludos ingleses y preguntas con `?` sin
  abrir.
- **El umbral estaba justo por encima de un caso real** (148 caracteres contra
  un mínimo de 150). Bajado a 130.

En vivo, ejecución 25682:

```
La extensión de visa cuesta *4,000 GYD* y se paga antes: ...

Lo que se necesita: el pasaporte no puede estar vencido. ...

Después de subir la aplicación, ... ¿Quiere que le ayudemos con el trámite?
```

---

## Detalles de montaje

**El nodo devuelve `{...item.json, output: normalizado}`**, así que
`Responder por WaCRM` sigue usando `$json.output` **sin cambiar su expresión**.
Eso es lo que permitió meterlo *antes* del envío sin riesgo — con un nodo
Postgres no se podría, porque cambia la forma del item y el mensaje saldría
vacío.

**`onError: continueRegularOutput`**: si el nodo falla, el mensaje sale igual.
Un problema de formato nunca puede impedir que el cliente reciba respuesta.

**El outbox guarda el texto normalizado**, no el original: se cambió
`$('Respuesta valida?')` por `$('Normalizar formato')` para que registre lo que
de verdad se envió.

---

## Lo que NO arregla

El **bloque lógico** de la Fase 3 —"máximo una solicitud lógica nueva por
turno"— es otro problema y no se toca aquí. El prompt actual dice *"una pregunta
por mensaje"*, que es literalmente la regla que el spec desaconseja: obliga a
pedir en dos turnos la tarjeta y el celular del mismo beneficiario, que son un
solo bloque.

Eso sí exige tocar el prompt. Ver `11-lenguaje-deliberativo-rompe-deepseek.md`
antes de intentarlo.
