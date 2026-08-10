# Vigilante de la ingesta de depósitos

Desplegado el **10 de agosto de 2026**, después de que la ingesta estuviera
**4 horas parada sin que saltara ninguna alarma**. Ver
`18-dos-caidas-silenciosas.md` para el incidente.

`Vigilante - ingesta de depositos MMG` — **`NiibUBRtOlOppmY4`**, cada 10 minutos.

---

## Qué vigila, y por qué no vigila lo obvio

**Prueba la credencial de cada buzón**, no el volumen de depósitos.

La idea intuitiva —avisar si hace mucho que no entra un depósito— **se descartó
midiendo**. Huecos reales entre depósitos en horario de negocio:

| Cuándo | Hueco |
|---|---|
| 7-ago | **4 h 05** |
| 5-ago | **3 h 50** |
| 8-ago | 2 h 22 |

Son períodos tranquilos **normales**. Con umbral de 3 h habría dado **dos falsas
alarmas en 5 días**, y el 10-ago habría avisado solo **42 minutos** antes de que
se descubriera a mano. Poco valor y mucho ruido.

Y tiene un punto ciego que lo descalifica: el **buzón de la app murió a las
00:23** y el de agente siguió alimentando el libro hasta las 14:02. Un vigilante
por volumen global **no lo habría visto nunca**.

> **Y una trampa de los datos:** `depositos_mmg.recibido_en` guarda la fecha del
> **correo**, no la de la ingesta. Cuando el 10-ago entró la cola de golpe, el
> histórico quedó continuo y la caída **desapareció de los datos**. Solo se ve en
> tiempo real, comparando contra `now()`.

---

## Cómo funciona

```
Cada 10 minutos
  → Probar buzon agente   (credencial jyZYkyuLqkU1Nral)
  → Probar buzon app      (credencial 2Ydg0vEfSSg8Vwog)
  → Evaluar
  → Avisar en el CRM
```

Cada nodo de Gmail hace una lectura mínima (`limit: 1`) contra
`from:notifications@mmg.gy`, con `onError: continueRegularOutput` para que un
fallo no tumbe el workflow. `Evaluar` comprueba que la respuesta trae un correo
de verdad (`id` y `From`); si no, ese buzón está caído.

> **El filtro NO lleva fecha, y es deliberado.** Hay cientos de correos
> históricos de MMG, así que una lectura buena **siempre** devuelve uno. Si
> alguien añadiera `newer_than:1d`, un buzón sano en un día tranquilo se
> confundiría con uno caído.

El aviso va **al CRM**, no por WhatsApp: es el canal que no depende de la
ventana de 24 h, que es justo lo que falla cuando hay problemas. Con **throttle
de 60 minutos** para no repetirlo cada pasada, y **nombra el buzón concreto**.

---

## Cómo se probó

Las tres caras, contra el sistema real:

| Prueba | Resultado |
|---|---|
| Todo funcionando | `hay_caida: false`, **0 avisos** |
| Buzón de agente roto (credencial inexistente) | detecta y crea **3 avisos**, uno por admin |
| Credencial restaurada | `hay_caida: false`, **no repite** |

> **La segunda prueba es la que valió la pena.** Detectaba la caída
> correctamente **y el INSERT reventaba** con `notifications_type_check`: el tipo
> `ingesta_caida` no estaba en la restricción. Sin probar el fallo, el vigilante
> habría quedado desplegado detectando bien y **sin poder avisar** — peor que no
> tenerlo, porque se daría por cubierto. De ahí sale la migración `058`.

---

## Lo que NO cubre

Prueba que **se puede leer el buzón**. No cubre:

- que **MMG deje de mandar correos** — el buzón se lee bien, simplemente no
  llega nada;
- que el **filtro del asunto** se rompa o MMG cambie el texto;
- que el correo llegue y **falle al parsearse**;
- que la **visión lea mal la referencia**, como el 10-ago a las 12:48, donde el
  TransID leído `20397544023399` nunca cuadró porque el correo decía
  `20397544023299` — **un dígito**.

Para eso hace falta el otro vigilante, el que mira **la consecuencia**: un deal
en «Por verificar» cuyo TransID no está en el libro pasados N minutos. Eso
significa literalmente *«hay un cliente esperando y no puedo cruzar su
depósito»*, y habría saltado el 10-ago sobre las **10:50** —casi tres horas
antes—, viniera el fallo de donde viniera.

**Queda pendiente**, y necesita medir cuánto tarda normalmente un depósito
legítimo en aparecer en el libro, para no avisar de algo que se resuelve solo en
dos minutos.

---

## Reversión

Desactivar el workflow `NiibUBRtOlOppmY4`. No toca datos ni depende nada de él.
La migración `058` puede quedarse: un tipo de aviso de más no molesta.
