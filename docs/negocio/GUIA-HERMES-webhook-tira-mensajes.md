# Guía para Hermes — El webhook de WhatsApp tira lotes enteros de mensajes

## Qué hay que hacer, en una frase

En `src/app/api/whatsapp/webhook/route.ts`, un mensaje cuyo remitente llega **sin
perfil** revienta con `TypeError` y se lleva por delante **todo el lote** del
webhook: no se crea contacto, ni conversación, ni mensaje, y como ya se
respondió `200` a Meta, **no hay reintento**. El mensaje del cliente desaparece
sin dejar rastro en la base.

Ha pasado **13 veces** en el log actual del VPS.

---

## 1. Cómo se descubrió

El 10-ago un cliente (`592 6731279`) escribió al número del negocio a las 9:00,
11:01, 14:31, 14:32 y 14:34, **con doble tick de entregado**, y en la base de
datos no hay absolutamente nada suyo: ni en `contacts`, ni en `conversations`,
ni en `messages`, ni en `session_events`. Nadie se enteró hasta que el cliente
escribió a Osmany por su cuenta.

No fue una caída: ese día entraron mensajes de clientes **todas las horas** de
06:00 a 16:00 (108 mensajes de 10 clientes solo en la hora de las 9:00).

En `~/.pm2/logs/wacrm-error.log` del VPS (`ubuntu@129.159.93.221`):

```
Error processing webhook: TypeError: Cannot read properties of undefined (reading 'name')
```

Trece veces, todas en las últimas 540 líneas del fichero. El log de pm2 no lleva
marcas de hora, pero se pueden fechar con los `wamid` de las líneas vecinas —
llevan el número del remitente en base64:

| Línea del log | Cuándo |
|---|---|
| 122234 (ancla, `wamid` de `5926095231`) | 10-ago **09:04:58** |
| **122235, 122237** — dos `TypeError` | **~09:05** |
| **122310–122316** — cuatro `TypeError` | entre las 09:05 y las 16:08 |
| 122330 (ancla, `wamid` de `5926095231`) | 10-ago **16:08:17** |

Los dos primeros caen en el minuto en que el cliente escribió por primera vez.

---

## 2. Dónde está exactamente el fallo

Tres sitios encadenados, todos en `route.ts`.

### a) El guardián deja pasar un array vacío

```ts
if (!value.messages || !value.contacts) continue
```

`value.contacts = []` es **truthy**: pasa el guardián. Y si Meta manda el array
vacío o sin el objeto `profile`, lo que viene después revienta.

### b) La lectura que revienta

```ts
const contact = value.contacts[i] || value.contacts[0]   // undefined si el array esta vacio
...
const contactName = contact.profile.name                 // ← TypeError aqui
```

### c) La excepción se lleva el lote entero

`processMessage` no tiene `try/catch` propio. El `TypeError` sube por
`processWebhook` hasta el `catch` de `after()`, que solo hace `console.error`.
Todo lo que quedara por procesar en ese webhook —incluidos mensajes de **otros**
clientes del mismo lote— se pierde con él.

Y como el `200` a Meta ya se devolvió antes de entrar en `after()`, **Meta da la
entrega por buena y no reintenta**.

---

## 3. El arreglo

Son tres cambios pequeños e independientes. Los tres, no uno.

### a) `contacts` es opcional — el teléfono no sale de ahí

El remitente se saca de `message.from`, no de `contacts`. Lo único que aporta
`contacts` es el **nombre de pantalla**, que es prescindible. No debe ser
requisito para aceptar el mensaje.

```ts
// antes
if (!value.messages || !value.contacts) continue
// despues
if (!value.messages) continue
```

y en el bucle:

```ts
const contact = value.contacts?.[i] ?? value.contacts?.[0]
```

### b) El nombre, con respaldo

`processMessage` recibe ahora un contacto que puede faltar. Cambia la firma a
`contact: { profile?: { name?: string }; wa_id?: string } | undefined` y:

```ts
const senderPhone = normalizePhone(message.from)
const contactName = contact?.profile?.name || senderPhone
```

El resto sigue igual: `findOrCreateContact` ya hace `name: name || phone`.

### c) Un mensaje malo no puede tumbar a los demás

Envuelve la llamada del bucle para aislar cada mensaje:

```ts
for (let i = 0; i < value.messages.length; i++) {
  const message = value.messages[i]
  const contact = value.contacts?.[i] ?? value.contacts?.[0]
  try {
    await processMessage(message, contact, config.account_id, config.user_id, decryptedAccessToken)
  } catch (err) {
    console.error('[webhook] mensaje descartado', JSON.stringify({
      wamid: message?.id, from: message?.from, type: message?.type,
      error: err instanceof Error ? err.message : String(err),
    }))
  }
}
```

**Esto por sí solo ya evita la pérdida en cadena**, aunque aparezca mañana otro
campo inesperado. Es la parte que no hay que dejarse.

---

## 4. Lo que hace falta aparte del arreglo: dejar rastro

Hoy WaCRM **no guarda nada de lo que Meta le entrega**. No hay ninguna tabla de
webhooks. Por eso este fallo fue invisible durante días: si el `INSERT` no
llega, no queda ni la huella de que el mensaje existió, y no hay forma de
distinguir «Meta nunca lo mandó» de «WaCRM lo tiró».

Propuesta mínima: una tabla `whatsapp_webhook_log` con
`(id, recibido_en, phone_number_id, wamid, remitente, tipo, procesado, error, payload jsonb)`,
escrita **antes** de procesar, y marcada como procesada al terminar. Con retención
corta (7–14 días) no pesa nada, y convierte cualquier pérdida futura en una
consulta de treinta segundos.

> Ojo con el contenido: el `payload` lleva mensajes de clientes. Que no salga de
> la base ni acabe en un log en claro.

---

## 5. Cómo se comprueba que quedó arreglado

1. **Prueba unitaria**, que es donde de verdad se ve: un `value` con
   `contacts: []` y un mensaje de texto. Antes lanza `TypeError`; después tiene
   que crear el contacto con el **teléfono como nombre** y guardar el mensaje.
2. Otra con `contacts: [{ wa_id: '...' }]` sin `profile` — mismo resultado.
3. Una tercera con **dos mensajes**, el primero malformado: el segundo tiene que
   guardarse igual. Esa es la que prueba el `try/catch` del bucle.
4. Después de desplegar, en el VPS: `grep -c "Error processing webhook"` sobre
   `~/.pm2/logs/wacrm-error.log` no debe subir, y si aparece
   `[webhook] mensaje descartado`, ahora sí dice de quién y por qué.

---

## 6. Por qué corre prisa

Un mensaje perdido aquí no es un mensaje perdido: es **un cliente que depositó
dinero y al que nadie contesta**. En este caso fueron 20.000 GYD (TransID
`10397460289689`) que estuvieron desde el 9-ago a las 13:07 en el libro sin que
nadie supiera de quién eran, y solo se resolvieron porque el cliente buscó a
Osmany por otra vía. El vigilante de depósitos sin cruzar
(`bTwsEJsmoAzsuOxm`) tampoco lo ve: sin conversación no hay deal, y sin deal no
hay nada que vigilar.
