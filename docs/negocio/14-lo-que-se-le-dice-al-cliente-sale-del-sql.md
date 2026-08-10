# Lo que se le dice al cliente sale del SQL, no del modelo

Desplegado en producción el **10 de agosto de 2026**. Un solo nodo: el
`Decisor` del Cerebro v2.

---

## El fallo, con nombre y apellidos

El 10-ago por la mañana un cliente mandó una **captura de una conversación de
WhatsApp** —no un comprobante— donde se veía el número de cuenta `6762167`. La
visión la tomó por comprobante y leyó ese número **como el importe**.

El SQL hizo su trabajo entero y bien:

```
DEPOSITO: 6,762,167 GYD - DESCONOCIDO
Ref: N/A
ALERTAS: Importe no está claro.
→ deal a Incidencia, aviso en el CRM
```

Y aun así el bot le escribió al cliente:

> *"Recibimos su depósito de **6,762,167 GYD**. Vemos que fue distinto a lo que
> hablamos, ningún problema, se le transfiere el equivalente de lo depositado."*

Osmany tuvo que entrar a mano cuatro segundos después.

---

## Por qué pasaba

En el `Decisor` había una línea que se ejecutaba **siempre** que se hubiera
leído un comprobante, dijera lo que dijera la verificación:

> *"Comprobante leido y YA REGISTRADO automaticamente en el tablero. NO hay tool
> que llamar para esto: solo confirmalo al cliente con palabras."*

`Cruzar deposito con MMG` corre **antes** que el `Decisor`, o sea que **el
veredicto ya estaba calculado** cuando se redactaba esa orden. Pero el `Decisor`
no lo leía nunca.

Las alertas de la visión sí se le pasaban al modelo, pero como un `Alerta: …`
suelto detrás de una orden imperativa. El modelo obedeció la orden.

**No es que el modelo desobedeciera: le estábamos ordenando confirmar.**

Es la misma lección del tramo 2C.2, en otro sitio: **un mensaje de texto no es
un control**. Si algo tiene que pasar sí o sí, tiene que pasar en el SQL o en el
dato, nunca en una frase que el modelo puede interpretar.

---

## Lo que hace ahora

El `Decisor` lee `$('Cruzar deposito con MMG').first().json.resultado` y elige
la instrucción según el veredicto:

| `resultado` | Qué se le ordena al agente |
|---|---|
| `verificado` | confirmar — **texto idéntico al de antes** |
| `ya_reclamado` | acusar recibo, **prohibido confirmar**, lo revisa una persona |
| `deposito_antiguo` | acusar recibo, **prohibido confirmar** |
| cualquier otro | "registrado pero TODAVÍA NO verificado", prohibido confirmar |
| lectura dudosa | **prohibido decir ninguna cifra** |

«Lectura dudosa» es `estado = DESCONOCIDO` o una alerta que contenga *"no esta
claro"*. Ese caso se comprueba **antes** que el veredicto: si no sabemos el
importe, no se menciona ningún número, punto.

**Falla del lado seguro:** si el nodo del cruce no llegó a ejecutarse, el
`try/catch` deja el veredicto en `desconocido` y cae en la rama genérica, que
acusa recibo sin confirmar. Antes, ese mismo caso confirmaba.

---

## Tres cosas que hay que saber para no meter la pata

**1. El cruce aproximado también devuelve `verificado`.** Lo de "aproximado" va
en `metodo`, no en `resultado`. Así que un cruce por plan B **se le confirma al
cliente igual que uno exacto**. Es coherente —el deal sí avanza a "Lista para
transferir"— pero conviene saberlo. Los valores reales de `resultado` son:
`verificado`, `ya_reclamado`, `deposito_antiguo`, `deposito_anulado`,
`monto_no_coincide`, `sin_correo`, `no_aplica`, `sin_referencia`.

**2. La comparación con la última cotización solo se emite si el veredicto es
`verificado`.** Esa nota termina diciendo *"se le transfiere el equivalente de
lo depositado"*, que es una confirmación encubierta. Emitirla junto a un
"todavía no está verificado" sería contradictorio.

**3. LA RAMA DE DUPLICADOS SIGUE SIN CONSULTAR EL CRUCE. Pendiente.** Si el
cliente reenvía la **misma imagen**, `Dedup comprobantes` la para antes y el
bloque nuevo ni se ejecuta: entra la rama de duplicados, que ordena *"acusa
recibo de su comprobante"* sin preguntarle a nadie. Resultado observado:
*"Recibimos su depósito de 39,000 GYD"* sobre un depósito ya consumido. Es menos
grave —el deal ya existía, no se mueve dinero— pero es la misma enfermedad.

---

## Cómo se redacta esto (importante)

Va como **mapeo plano estado → instrucción**. Nada de pedirle al modelo que
valore, compare o decida: eso enciende el modo pensamiento de DeepSeek y **rompe
la conversación en el turno siguiente**. Ha pasado el 1, el 5 y el 9 de agosto.
Ver `11-lenguaje-deliberativo-rompe-deepseek.md`.

Por eso las instrucciones nuevas son frases cortas y afirmativas con PROHIBIDO
explícito, no condicionales para que el modelo resuelva.

---

## Cómo se verificó

**Sin tocar producción**, en este orden:

1. **En seco**, ejecutando el bloque nuevo fuera de n8n con los ocho casos
   posibles. El camino `verificado` produce el texto **byte a byte idéntico** al
   anterior.
2. **Contra la función real**, con `p_simular = true` dentro de un
   `DO $$ … RAISE EXCEPTION … $$` que lo revierte todo. Confirmó que el veredicto
   bueno se llama exactamente `verificado` — si se hubiera llamado de otro modo,
   el código habría dejado de confirmar depósitos buenos **a todos los
   clientes**, en silencio:

```
BUENO(reciente,libre) -> verificado/exacto
YA USADO              -> ya_reclamado
ANTIGUO               -> deposito_antiguo
REFERENCIA INVENTADA  -> sin_correo
```

3. **De punta a punta**, con un comprobante real del 4-abr al número de pruebas
   (ejecución `26962`): cruce `deposito_antiguo` → rama nueva → el bot contestó
   *"Recibimos su comprobante. Una persona del equipo lo está revisando, en breve
   le confirmamos."* Sin cifra y sin confirmar. Antes habría dicho *"Recibimos su
   depósito de 30.000 GYD… se le transfiere el equivalente"*.

**Lo que NO se pudo probar de punta a punta:** el camino `verificado`, porque
hacía falta un comprobante fresco que nadie tenía. Queda cubierto por los pasos
1 y 2 y por el primer comprobante real que entre.

---

## Reversión

`ROLLBACK-v2-antes-contexto-comprobante.json`. Es un cambio de parámetros, no
estructural: se aplica solo, sin ciclo de desactivar/activar, y revertirlo es
restaurar el `jsCode` del `Decisor`. No toca datos.
