# El nombre de un contacto se revierte solo

**13-ago-2026.** Lo reporta Osmany: renombra un contacto desde el apartado de
contactos, se guarda bien, y **al rato vuelve a llamarse como antes**.

Ejemplo suyo: le escribe Fran, él lo tiene en su celular como «Fran Guyana», lo
pone así en el CRM, se guarda… y luego vuelve a salir «Fran».

No es la pantalla de contactos: **el guardado funciona**. Lo que pasa es que el
webhook de WhatsApp lo pisa en el siguiente mensaje del cliente.

---

## La causa exacta

`src/app/api/whatsapp/webhook/route.ts`, función `findOrCreateContact`
(alrededor de la **línea 1183**):

```ts
if (existingContact) {
  // Update name if it changed
  if (name && name !== existingContact.name) {
    await supabaseAdmin()
      .from('contacts')
      .update({ name, updated_at: new Date().toISOString() })
      .eq('id', existingContact.id)
  }
  return { contact: existingContact, wasCreated: false }
}
```

Y ese `name` viene de **el perfil del cliente**, no del CRM — línea **701**:

```ts
const contactName = contact?.profile?.name || senderPhone
```

Así que con **cada mensaje entrante**, si el nombre guardado no coincide con el
que el cliente tiene puesto en su propio WhatsApp, se sobrescribe. La edición de
Osmany dura exactamente hasta el siguiente mensaje de ese cliente.

La intención original se lee en el comentario («Update name if it changed»): que
el CRM siguiera los cambios de nombre del cliente. Nadie contempló que una
persona pusiera el nombre a propósito.

**Medido:** **29 de los 84 contactos** han sido reescritos alguna vez
(`updated_at > created_at + 1 min`).

---

## Lo que ya está hecho (no toques la base)

**Migración `080_origen_del_nombre_del_contacto`, ya aplicada en producción.**
Añade la columna que falta para poder distinguirlo:

```sql
contacts.name_source text NOT NULL DEFAULT 'whatsapp'
  CHECK (name_source IN ('whatsapp','manual'))
```

- `whatsapp` → el nombre vino del perfil del cliente, **el webhook puede
  refrescarlo**.
- `manual` → lo escribió una persona en el CRM, **nadie lo pisa**.

Backfill ya ejecutado: **82 contactos quedaron en `manual`** (todos los que hoy
tienen un nombre distinto de su teléfono — el libro que Osmany tiene ahora es el
que quiere, se protege entero) y **2 en `whatsapp`** (los que se llaman como su
número, para que el perfil les ponga nombre cuando llegue).

La columna es aditiva y ahora mismo **no hace nada**: el app hace `select('*')` e
`insert` sin nombrarla. No rompe nada mientras el código no la lea.

---

## Los tres cambios de código

### 1. El webhook deja de pisar lo manual

`src/app/api/whatsapp/webhook/route.ts`, en el bloque de arriba:

```ts
if (existingContact) {
  // El nombre del perfil de WhatsApp SOLO rellena lo que nadie ha tocado.
  // Si una persona lo edito en el CRM (name_source='manual'), no se pisa:
  // hasta el 13-ago Osmany renombraba un contacto y el siguiente mensaje
  // del cliente lo devolvia a su nombre de WhatsApp.
  if (
    name &&
    name !== existingContact.name &&
    existingContact.name_source !== 'manual'
  ) {
    await supabaseAdmin()
      .from('contacts')
      .update({ name, updated_at: new Date().toISOString() })
      .eq('id', existingContact.id)
  }
  return { contact: existingContact, wasCreated: false }
}
```

`findExistingContact` ya hace `select('*')`, así que `name_source` viene en la
fila sin tocar la consulta.

### 2. El tipo, porque aquí el build no avisa

`src/lib/contacts/dedupe.ts`, interfaz `ExistingContact`: añadir el campo.

```ts
export interface ExistingContact {
  id: string
  phone: string
  name?: string | null
  name_source?: string | null   // <-- nuevo
  [key: string]: unknown
}
```

**Esto no es cosmético.** La interfaz tiene `[key: string]: unknown`, así que sin
declararlo `existingContact.name_source` compila igual como `unknown` y la
comparación pasa de largo — y el build de este proyecto **no valida tipos**, así
que nadie te avisaría.

### 3. Guardar desde el CRM marca `manual`

`src/components/contacts/contact-form.tsx`, en las **dos** ramas (línea ~154 el
`update`, línea ~166 el `insert`): añadir `name_source: 'manual'` al payload.

Si no se hace, un contacto renombrado hoy seguiría marcado `whatsapp` y el
webhook lo volvería a pisar — que es justo el fallo que estamos cerrando.

**Opcional, mismo criterio:** `src/components/contacts/import-modal.tsx`, la
importación por CSV. Un nombre de un CSV también lo puso una persona.

---

## Cómo se comprueba que quedó bien

**La prueba de verdad es un mensaje real**, no el test:

1. Renombra un contacto en el CRM a algo que no sea su nombre de WhatsApp.
2. Que esa persona te escriba (o escríbele y que conteste).
3. El nombre **tiene que seguir siendo el tuyo**.

Y en la base, que no se haya movido:

```sql
SELECT name, phone, name_source, updated_at
  FROM contacts WHERE phone = '<el telefono>';
```

**Y el control al revés, que es el que demuestra que no lo mataste del todo:** un
contacto con `name_source='whatsapp'` (hoy solo hay 2, los que se llaman como su
número) **sí** debe recibir el nombre del perfil en su próximo mensaje.

Para el test automático, `src/app/api/whatsapp/webhook/route.test.ts` ya tiene el
andamiaje: un caso con `findExistingContact` devolviendo
`{ id, phone, name: 'Fran Guyana', name_source: 'manual' }` y perfil «Fran» no
debe producir ningún `update` sobre `contacts`.

---

## Reversión

```sql
ALTER TABLE contacts DROP COLUMN name_source;
```

Y deshacer los tres cambios. Nada más depende de esa columna.
