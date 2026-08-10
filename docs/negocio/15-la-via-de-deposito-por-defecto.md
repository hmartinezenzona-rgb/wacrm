# La vía de depósito: cuando el cliente no elige, es AGENTE

Cambio en el prompt del agente, desplegado el **10 de agosto de 2026**.

---

## Hay dos cuentas y no son intercambiables

| Vía | Titular | Número |
|---|---|---|
| **Agente MMG** | Osmany Pozo | **6762167** |
| App MMG (Pay Merchant) | Osmany Services | 6990225 |

La de agente sirve cuando el cliente **transfiere desde su cuenta personal** o
deposita con un agente. La de Pay Merchant, cuando paga **desde la app MMG**.

---

## Lo que pasó, y por qué importa

El 10-ago un cliente escribió *«Me mandas la cuenta y lo transfiero y usted lo
envía a la cuenta que yo le mandé»*. Eso **no es elegir app**: es una
transferencia desde cuenta personal, o sea la vía de **agente**.

El bot le dio **Pay Merchant 6990225**. El cliente le corrigió —*«Eso es nuevo
ahora porque siempre lo hemos hecho así»*— y el bot **insistió**: *«Sí, así es
como se deposita ahora»*.

El cliente entonces mandó una **captura de una conversación anterior** como
prueba de cuál era su cuenta de siempre. La visión leyó esa captura como
comprobante, tomó el número de cuenta `6762167` **por importe**, y el bot le
anunció un depósito de 6.762.167 GYD que nunca existió.

> **Sin este fallo no hay captura, y sin captura no hay deal fantasma.** Toda la
> cadena del 10-ago —incluido el susto de los 6,7 millones— arranca aquí, no en
> la visión.

---

## El dato que decide cuál es el valor por defecto

Sobre **todos** los comprobantes registrados hasta el 10-ago:

| Vía | Comprobantes |
|---|---|
| **Agente MMG (6762167)** | **26** |
| App MMG Pay Merchant (6990225) | 1 |

El bot estaba dando por defecto la cuenta que usa **1 de cada 27 depósitos**.

**Criterio confirmado por Humberto el 10-ago:** si el cliente no especifica, se
le da **siempre la de agente**.

---

## Lo que ya estaba en el prompt y no se cumplió

El prompt ya decía *«esto SÍ se pregunta SIEMPRE, no se asume nunca»* y traía
este contraejemplo, que describe con exactitud lo que ocurrió:

> `## MAL: 'Ya que deposita desde la app, hágalo por App MMG a...' — el cliente
> NUNCA dijo app. Inventarlo lo obliga a corregirte`

El bot **preguntó dos veces**, correctamente. El cliente no contestó ni «app» ni
«agente» ninguna de las dos. Y ahí, sin valor por defecto escrito, el modelo
eligió el que no era.

**La lección:** una regla que prohíbe asumir **no basta si no dice qué hacer
cuando falta el dato**. El hueco lo rellena el modelo.

---

## Cómo está escrito ahora

Como **mapeo plano**, nunca en prosa deliberativa —eso enciende el modo
pensamiento de DeepSeek y rompe la conversación en el turno siguiente. Ver
`11-lenguaje-deliberativo-rompe-deepseek.md`.

```
- Agente: Titular Osmany Pozo, cuenta MMG 6762167.  <- ESTA ES LA POR DEFECTO
MAPEO. Lo que dice el cliente -> la via que le das:
  dice 'app' -> App (Pay Merchant) 6990225
  dice 'agente' -> Agente 6762167
  'te transfiero' -> Agente 6762167
  'me mandas la cuenta' -> Agente 6762167
  'desde mi cuenta' -> Agente 6762167
  'como siempre' -> Agente 6762167
  ya preguntaste y no dijo la palabra 'app' -> Agente 6762167
Solo das Pay Merchant 6990225 si el cliente dice la palabra 'app'.
```

Se sigue preguntando la vía la primera vez. Lo que cambia es qué pasa cuando la
respuesta no llega.

---

## Cómo se verificó

**La prueba que nunca se salta, primero:** una consulta normal de remesa contra
la conversación de pruebas. Sigue igual — se ejecutan `consultar_tasas` y
`calcular_envio`, y responde *«Por 30,000 GYD llegan 90,000 CUP»*. La tasa (3,0
desde el 10-ago a las 10:07 UTC) se comprobó contra la tabla `tasas`: **no se la
inventó**.

**Y después el caso nuevo**, con el mensaje exacto que falló por la mañana:

```
C: me mandas la cuenta y lo transfiero
→ 'Perfecto. Deposite a:
   *Titular:* Osmany Pozo
   *Cuenta MMG:* 6762167
   ¿Me pasa la tarjeta y el celular de quien recibe en Cuba?'
```

Las dos pruebas se lanzaron con el webhook firmado contra la **conversación de
pruebas**, y se vació `cerebro_memoria` de esa sesión al terminar.

---

## Reversión

`ROLLBACK-v2-antes-via-agente-por-defecto.json`. Es un cambio de parámetros: se
aplica solo y revertirlo es restaurar el `systemMessage` del nodo
`Agente Remesas`.

---

## Lo que queda por decidir

Esto es **una instrucción, no un control**. Si el modelo empieza a saltársela, la
vía robusta es que el `Decisor` inyecte la cuenta que toca —como ya hace con la
cuenta habitual del cliente— en vez de confiar en el prompt. Requiere decidir
cómo se detecta la vía a partir del texto, que es la parte difícil.
