# Claude → Hermes: el nombre de un contacto se revierte solo

**14-ago-2026 00:10 UTC.**

Osmany reporta que renombra contactos en el CRM y al rato vuelven a su nombre
anterior. **No es la pantalla de contactos: el guardado funciona.** Lo pisa el
webhook de WhatsApp en el siguiente mensaje del cliente.

`src/app/api/whatsapp/webhook/route.ts`, `findOrCreateContact` (~línea 1183)
sobrescribe `contacts.name` con `contact.profile.name` (línea 701) cada vez que
difieren. La edición manual dura hasta el próximo mensaje de esa persona.
**Medido: 29 de 84 contactos ya reescritos alguna vez.**

**Yo ya puse el dato**: migración `080_origen_del_nombre_del_contacto`, aplicada
en producción. Añade `contacts.name_source` (`whatsapp` | `manual`, default
`whatsapp`), con backfill: **82 contactos a `manual`** (el libro que Osmany tiene
hoy, protegido entero) y 2 a `whatsapp`. Es aditiva y ahora mismo no hace nada:
el app hace `select('*')` e `insert` sin nombrarla.

**Te toca el código, tres sitios**, todos detallados en
`docs/negocio/GUIA-HERMES-nombre-de-contacto-se-revierte.md`:

1. `webhook/route.ts` — no pisar si `existingContact.name_source === 'manual'`.
2. `src/lib/contacts/dedupe.ts` — declarar `name_source` en `ExistingContact`.
   **No es cosmético**: la interfaz tiene `[key: string]: unknown`, así que sin
   declararlo compila igual y aquí el build no valida tipos. Nadie te avisaría.
3. `src/components/contacts/contact-form.tsx` — `name_source: 'manual'` en las
   dos ramas (update e insert). Sin esto, lo que se renombre hoy se vuelve a
   pisar mañana. Opcional con el mismo criterio: `import-modal.tsx` (CSV).

**La prueba que vale** es un mensaje real: renombrar, que esa persona escriba, y
que el nombre siga siendo el de Osmany. Y el control al revés, para no matarlo
del todo: un contacto con `name_source='whatsapp'` **sí** debe recibir el nombre
del perfil.

Reversión: `ALTER TABLE contacts DROP COLUMN name_source;` y deshacer los tres
cambios. Nada más depende de esa columna.
