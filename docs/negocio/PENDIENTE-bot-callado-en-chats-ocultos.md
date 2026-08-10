# Pendiente — El bot debe callar en los chats ocultos

> ## ✅ IMPLEMENTADO Y VERIFICADO EL 9-AGO-2026
>
> Se hizo exactamente como estaba especificado aquí abajo, sin desviaciones.
> Las cuatro pruebas de la última sección pasaron. Verificado en la ejecución
> 25195: `oculta: true` → `ruta: silencio` → `Silencio admin` → `Cerrar lote`,
> con 0 eventos atascados.
>
> Copia previa del workflow: `ROLLBACK-v2-antes-chats-ocultos.json`.
> Resumen en `PENDIENTES.md`. **Este documento se conserva como registro de la
> especificación, no como pendiente.**

**Estado:** ~~especificado, NO implementado~~ → **hecho el 9-ago-2026.**
Decidido el 2026-08-07 y aplazado entonces para no tocar producción con el
negocio a punto de abrir.

**Es un cambio del Cerebro (n8n), no de WaCRM.** Hermes no interviene.

---

## Comportamiento deseado

| Situación | Qué debe pasar |
|---|---|
| El operador oculta o borra un chat | El bot **deja de responder** en esa conversación |
| El cliente vuelve a escribir | El chat reaparece en la lista **y el bot vuelve a actuar con normalidad** |

## Por qué hace falta

Hoy ocultar un chat **no calla al bot**. Comprobado en producción el 2026-08-07:

```
12:41:52  el cliente escribe "Hola"
12:42:07  el operador oculta el chat
12:42:10  el bot responde "Buenos días, ¿en qué le ayudo?"  ← con el chat ya oculto
```

Esa respuesta salió a un cliente real y el operador no la ve en ninguna parte.
Se puede tener una conversación entera —cotización, datos del beneficiario—
invisible para el equipo.

## Cómo se implementa

Dos cambios pequeños, ambos en el workflow `Cerebro v2` (`T3v07IQqtMs6AKJ4`).

### 1. Nodo `Contexto conversacion`

Añadir una columna al SELECT que ya existe:

```sql
(v.deleted_at IS NOT NULL) AS oculta
```

### 2. Nodo `Decisor`

Junto a la comprobación de `ctx.asignado`, que ya hace exactamente esto mismo:

```js
if (ctx.oculta) {
  return [{ json: { ruta: 'silencio', motivo: 'chat oculto por el operador' } }];
}
```

La ruta `silencio` ya existe y termina en `Silencio admin` → `Cerrar lote`, así
que el lote se cierra bien y no quedan eventos atascados. No hace falta tocar
el cableado.

## Por qué esto basta y no hace falta nada más

WaCRM ya pone `deleted_at = NULL` cuando entra un mensaje del cliente, **antes**
de llamar al webhook del Cerebro. Así que cuando el Cerebro procesa el lote
—12 segundos después, por el debounce— la conversación ya está visible y el bot
actúa con normalidad. El "vuelve a actuar si el cliente escribe" sale gratis.

## Límite conocido

Si el operador oculta el chat con una ejecución del Cerebro ya en vuelo y
pasada la lectura del contexto, esa respuesta concreta sale igual. Es una
ventana de segundos y no merece complicar el flujo.

## Mientras tanto

Para callar al bot en una conversación **hoy**, el mecanismo que sí funciona es
**asignar el chat a un humano**. Eso ya lo respeta el Decisor
(`ctx.asignado` → ruta `silencio`). Ocultar no sirve para eso todavía.

## Pruebas cuando se implemente

1. Ocultar un chat → escribir desde otro número al negocio → el bot **no** responde en el oculto
2. Que el cliente del chat oculto escriba → el chat reaparece **y** el bot responde
3. Comprobar que no quedan eventos en `processing` ni `retry_wait` tras el silencio
4. Un chat normal, sin ocultar, sigue funcionando igual
