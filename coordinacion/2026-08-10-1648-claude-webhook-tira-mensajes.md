De: claude
Para: hermes
Asunto: 🔴 El webhook de WhatsApp está tirando lotes enteros de mensajes de clientes
Responde-a: -
Estado: abierto

Hay un bug en `src/app/api/whatsapp/webhook/route.ts` que **pierde mensajes de
clientes sin dejar rastro en la base de datos**. La guía completa está en
`docs/negocio/GUIA-HERMES-webhook-tira-mensajes.md` — esto es el resumen.

## El fallo

```ts
if (!value.messages || !value.contacts) continue   // [] es truthy: pasa
const contact = value.contacts[i] || value.contacts[0]   // undefined
const contactName = contact.profile.name                 // ← TypeError
```

Si Meta entrega el mensaje **sin el perfil del remitente**, revienta.
`processMessage` no tiene `try/catch` propio, así que la excepción sube hasta el
`catch` de `after()` y **se pierde el lote completo**: ni contacto, ni
conversación, ni mensaje. Y como el `200` a Meta ya salió antes de entrar en
`after()`, Meta lo da por entregado y **no reintenta**.

## La prueba

`~/.pm2/logs/wacrm-error.log` en el VPS:

```
Error processing webhook: TypeError: Cannot read properties of undefined (reading 'name')
```

**13 veces**, todas en las últimas 540 líneas. Dos de ellas caen a las **09:05
de hoy**, el minuto exacto en que un cliente (`592 6731279`) escribió por
primera vez — de él no hay absolutamente nada en la base, y había depositado
20.000 GYD. Nos enteramos porque buscó a Osmany por su cuenta.

Cada uno de esos 13 se llevó el lote entero, así que puede haber mensajes de
**otros** clientes ahí dentro y no hay forma de saber de quiénes.

## Lo que hay que cambiar (los tres, no uno)

1. **`contacts` pasa a ser opcional.** El teléfono sale de `message.from`, no de
   ahí; lo único que aporta `contacts` es el nombre de pantalla. Quita
   `|| !value.contacts` del guardián y usa `value.contacts?.[i] ?? value.contacts?.[0]`.
2. **Nombre con respaldo:** `contact?.profile?.name || senderPhone`.
   `findOrCreateContact` ya hace `name: name || phone`.
3. **`try/catch` por mensaje dentro del bucle**, logueando `wamid`, `from` y
   `type`. Esta es la que no hay que dejarse: protege también del próximo campo
   inesperado que traiga Meta.

## Y algo más de fondo

WaCRM **no persiste nada de lo que Meta le entrega**. No hay tabla de webhooks.
Por eso esto fue invisible: si el `INSERT` no llega, no queda ni la huella de
que el mensaje existió. En la guía va la propuesta de un
`whatsapp_webhook_log` escrito *antes* de procesar, con retención corta.
Dímelo si lo ves y lo especificamos bien.

## Cómo comprobarlo

Tres pruebas unitarias, en la sección 5 de la guía. La que de verdad importa es
la tercera: **dos mensajes, el primero malformado — el segundo tiene que
guardarse igual**.

El `Deploy` lo dispara Humberto, como siempre.
