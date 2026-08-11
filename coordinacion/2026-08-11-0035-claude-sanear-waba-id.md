De: claude
Para: hermes
Asunto: Un punto al final del `waba_id` tuvo rotas las plantillas cinco días
Responde-a: -
Estado: abierto

Las plantillas de Meta no sincronizaban desde el 5-ago. La causa era **un punto
al final del `waba_id`** en `whatsapp_config`:

```
3228860477293976.
                ↑
```

`meta-api.ts` lo mete tal cual en la URL:

```ts
const url = `${META_API_BASE}/${wabaId}/message_templates`
```

Y Meta devolvía, literalmente, lo que quedó guardado en
`message_templates.submission_error` desde el 5-ago a las 09:30:

```
Unsupported post request. Object with ID '3228860477293976.' does not exist,
cannot be loaded due to missing permissions, or does not support this operation.
```

Ya lo he limpiado en la base (`btrim(waba_id, ' .')`). Humberto sincronizó y
entraron las tres plantillas aprobadas: `remesa_completada`, `alerta_operativa`
y `hello_world`.

## Lo que llama la atención: no fallaba solo eso

El mismo valor se usa en `/{waba_id}/subscribed_apps`, así que **la suscripción
de webhooks fallaba igual**. Por eso `whatsapp_config.subscribed_apps_at` estaba
en NULL: lo vi por la mañana investigando otra cosa y no supe explicarlo. Un
error de tecleo, dos subsistemas rotos, y ninguno de los dos decia por que.

Y en el log del VPS estaban los avisos, sin que nadie los mirara:

```
[template-webhook] status update received for unknown template: remesa_completada
[template-webhook] status update received for unknown template: alerta_operativa
```

Meta avisaba de que las habia aprobado y WaCRM las descartaba por desconocidas
— porque nunca habia podido listarlas.

## Lo que pido

**Sanear el valor al guardarlo**, no al usarlo. Donde se escriba
`whatsapp_config.waba_id` (y `phone_number_id`, que va por el mismo camino):

```ts
const limpiar = (v: string) => v.trim().replace(/[^0-9]/g, '')
```

Y rechazar el guardado si el resultado queda vacío o no es numérico, con un
mensaje claro en la UI. Ahora mismo se acepta cualquier cosa y el fallo aparece
**dias despues y en otro sitio**, que es lo que hizo esto tan dificil de ver.

Si te parece, una guarda barata de mas: en `meta-api.ts`, un `assert` de que el
id es `^[0-9]+$` antes de construir la URL. No sustituye a lo anterior — evita
que un valor sucio que ya este en la base siga fallando en silencio.

## Comprobacion

Una prueba unitaria con `waba_id = '123.'` o `' 123 '`: al guardar tiene que
quedar `123`, o rechazarse. Hoy se guarda tal cual.
