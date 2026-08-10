# No prometer la transferencia si no se sabe a quién

Desplegado el **10 de agosto de 2026**. Toca **dos workflows distintos**, y ahí
está lo importante: uno de ellos no es el Cerebro.

---

## El caso, con su fecha delante

Cliente **fran garcia**, el **10 de agosto**:

| Hora (UTC) | Quién | Qué |
|---|---|---|
| 14:45:51 | Cliente | manda el comprobante |
| 14:46:24 | Bot | *«Recibimos su depósito de 5.000 GYD… si gusta puede ir dándonos los datos de quien recibe»* ✔ |
| **15:05:10** | **Osmany** | *«Fran cuando puedas me pasas los datos para poner en Cuba»* |
| **15:05:40** | **Bot** | *«ya fue verificado. **En breve le hacemos la transferencia.**»* |
| 15:32:59 | Cliente | manda la tarjeta — todavía sin celular |

El bot prometió transferir **30 segundos después** de que una persona pidiera por
el mismo chat los datos que faltaban. No sabía a quién.

---

## Eran dos sitios, y uno no es el Cerebro

Todo el trabajo del 10-ago sobre lo que el bot confirma vivía en el `Decisor`.
Este mensaje **no salía de ahí**.

| Origen | Cuándo actúa | Nodo |
|---|---|---|
| **`WaCRM - Notificar cliente por etapa del deal`** (`wGud0KGR6eMqqfMQ`) | verificación **manual**: alguien arrastra el deal a «Lista para transferir» | `Filtrar cambio de etapa` |
| **Cerebro v2** | verificación **automática**: el cruce contra el correo de MMG | `Decisor` |

El notificador disparaba una plantilla fija:

```js
mensaje = 'Su deposito de *X GYD* ya fue verificado. En breve le hacemos la transferencia.';
```

Sin mirar nunca si se sabía el destino.

> **La pista que lo delató fue la ortografía.** *«Su deposito»* sin tilde, igual
> que en un mensaje del 8-ago a otro cliente. Eso no es prosa del agente: es una
> plantilla. Buscar el patrón repetido ahorró media hora de mirar el prompt.

---

## Hacen falta SIEMPRE los dos datos

Criterio de Humberto: tarjeta **y** celular. Con uno solo no se puede transferir,
así que el bot pide **exactamente el que falta**.

| Situación | Qué dice |
|---|---|
| Tarjeta y celular | *«En breve le hacemos la transferencia.»* |
| Solo tarjeta | *«…nos falta **el celular** de quien recibe en Cuba»* |
| Solo celular | *«…nos falta **la tarjeta** de quien recibe en Cuba»* |
| Ninguno | *«…nos falta **la tarjeta y el celular**»* |
| Zelle completo | *«En breve le hacemos la transferencia.»* |
| Zelle sin cuenta o sin nombre | pide el dato que falte |

**Medido antes de exigirlo**, para no bloquear envíos buenos:

| Tipo | Filas vigentes | Completos |
|---|---|---|
| `cuban_card` | 9 | **9 con tarjeta Y celular** |
| `zelle` | 14 | **14 con cuenta Y nombre** |

Ningún caso legítimo tiene un solo dato. Exigir los dos no rompe nada de lo que
hay.

---

## Cómo lo sabe cada uno

**El notificador** lee `rec.notes`, que ya viene en el webhook — sin consulta
extra. Las cabeceras reales son solo dos: `BENEFICIARIO (auto)` y
`BENEFICIARIO ZELLE`. Comprobado que el marcador en notas coincide **1 a 1** con
la tabla `remittance_beneficiaries` en las cuatro etapas (20/20, 1/1, 1/1, 1/1),
así que es fuente fiable.

**El Cerebro** usa `Contexto conversacion`, que ahora devuelve
`tiene_beneficiario` exigiendo completitud por tipo. Mira **toda la conversación
acumulada**, no solo el lote: la tarjeta pudo llegar hace tres mensajes y el
celular ahora. El `Decisor` combina eso con lo que traiga el lote actual:

```js
const sabeDestino = !!((tarjetaCtx && celularCtx) || s.datos_zelle || ctx.tiene_beneficiario);
```

---

## Cómo se verificó

**Sin tocar producción**, salvo la conversación de pruebas:

1. `PREPARE` de la consulta **completa** de `Contexto conversacion`. Firma
   `{text,text}`, **sin cambios de parámetros**.
2. Las siete ramas de cada lado, en seco, con notas reales sacadas de la base.
3. **End-to-end**, creando un deal de prueba en la conversación de pruebas y
   moviéndolo de etapa para disparar el notificador de verdad:

```
sin beneficiario  -> "…nos falta la tarjeta y el celular de quien recibe en Cuba. ¿Me los pasa?"
con los dos       -> "…En breve le hacemos la transferencia."       (23 s después, mismo deal)
solo la tarjeta   -> "…nos falta el celular de quien recibe en Cuba. ¿Me lo pasa?"
```

4. Tráfico real comprobado inmediatamente después de cada despliegue.
5. Deals, operaciones y memoria de la prueba borrados.

---

## Reversión

| Qué | Workflow | Copia |
|---|---|---|
| No prometer sin beneficiario | Cerebro | `ROLLBACK-v2-antes-sin-beneficiario.json` |
| | Notificador | `ROLLBACK-notificador-antes-sin-beneficiario.json` |
| Exigir los dos datos | Cerebro | `ROLLBACK-v2-antes-beneficiario-completo.json` |
| | Notificador | `ROLLBACK-notificador-antes-beneficiario-completo.json` |

---

## Leer las conversaciones con su fecha delante

Instrucción de Humberto el 10-ago, y evitó dos conclusiones falsas el mismo día.

**No se empata una conversación de hace tres días con una de hoy.** El sistema
cambia varias veces al día, así que el mismo síntoma en dos fechas puede tener
causas distintas.

> **La trampa concreta:** al buscar cuándo se registró cada beneficiario, todos
> los del 8-ago aparecían creados el **09-08 a las 17:51:55**, el mismo segundo.
> Eso no es cuando el cliente dio los datos: es el **backfill de la migración
> `042`**. Usarlo como prueba habría llevado a acusar al bot de fallos que no
> cometió ese día. Los del 10-ago sí son fiables, porque ya los escribe el
> trigger en vivo.

Al revisar una conversación, filtrar por día (`created_at::date`) y leerla
entera y en orden. El contexto de un mensaje son los mensajes de **ese día**.

---

## Lo que queda pendiente de aquí

**8 de los 28 deals en «Entregada» no tienen beneficiario registrado.** Se
entregó dinero y el sistema no sabe a quién. Es la **deuda 11**, que el 8-ago
eran 2 y el 10-ago son 8. No lo arregla este cambio: esto evita que vuelva a
crecer, pero los que ya están se resolvieron por fuera y su rastro no existe.
