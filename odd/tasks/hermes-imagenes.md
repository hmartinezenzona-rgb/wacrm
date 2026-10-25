# Hermes: recibir imágenes en el chat

## Objetivo
Que el admin pueda adjuntar una imagen (comprobante, captura) al preguntarle a
Hermes, y que Hermes la vea con su propio modelo — DeepSeek es multimodal
desde la nota del 2026-10-17 y su documentación lo confirma — sin pasar por
Gemini.

## Problema
`/api/hermes/chat` solo transporta texto: `cleanMessages` descarta cualquier
`content` que no sea una cadena, y corta en 8000 caracteres. El API server de
Hermes ya acepta contenido multimodal (`image_url` con `data:image/...` o
http), así que el bloqueo está en el panel.

## Alcance
- Panel: aceptar partes de contenido en la ruta, con una imagen por mensaje,
  solo `data:image/{jpeg,png,webp}`, con tope de tamaño; el texto conserva sus
  límites de hoy.
- Navegador: botón de adjuntar, compresión antes de enviar (lado mayor 1600 px,
  JPEG 0,82), miniatura con opción de quitar, y la imagen dentro de la burbuja
  del usuario.
- Las imágenes viven en memoria: al guardar la conversación en sessionStorage
  se descarta el base64 (cuota del navegador), así que tras recargar la
  pestaña queda el texto y el aviso de que hubo una imagen.

## Fuera de alcance
- Cambiar el gateway de Hermes (`image_input_mode: native`) se hace después,
  con respaldo de `config.yaml` y reinicio; sin eso Hermes mandaría la imagen a
  su backend de visión auxiliar (Gemini).
- La herramienta de comprobantes del Core (adaptador de receipts).

## Criterios de aceptación
- La ruta acepta `content: [{type:'text'}, {type:'image_url'}]` y reenvía la
  imagen intacta.
- Rechaza URL remotas, más de una imagen por mensaje, formatos que no sean
  jpeg/png/webp y cuerpos por encima del tope.
- Un mensaje solo con imagen funciona; un mensaje sin texto ni imagen no.
- La pantalla no se rompe sin `canvas` ni con un archivo que no es imagen.

## Comprobaciones
- `npx vitest run src/app/api/hermes src/lib/hermes src/components/hermes`
- `npx tsc --noEmit`
- Suite completa.

## Tareas
- [x] T1 — `lib/hermes/message-content.ts`: tipos, validación y `cleanMessages` con partes; sus pruebas. Commit 42ea912.
- [x] T2 — ruta `/api/hermes/chat` usa el módulo nuevo, con tope de cuerpo (413); pruebas de aceptación y rechazo. Commit 42ea912.
- [x] T3 — `lib/hermes/compress-image.ts`: cálculo de escala puro y compresión; pruebas del cálculo. Commit 05b425b.
- [x] T4 — compositor: adjuntar, miniatura, quitar, enviar con imagen; burbuja con imagen. Commit 05b425b.
- [x] T5 — persistencia sin base64 en sessionStorage. Commit 05b425b.
- [x] T6 — gateway de Hermes en `image_input_mode: native` (respaldo `config.yaml.bak.20261025_230002.pre-vision`, servicio `hermes-gateway-wacrm` reiniciado y activo).
- [ ] T7 — publicar el panel y probar con una imagen real (admin de prueba + borrado posterior).

## Verificación
- DeepSeek acepta la imagen con el nombre que usa Hermes: `POST /chat/completions` con `model: deepseek-v4-flash` y una imagen base64 devuelve 200; la respuesta reporta `model: deepseek-flash` y su razonamiento leyó el texto de la prueba ("TRANSFER 4 27 500" / "REF 88213").
- Suite: 3312 pruebas en verde; `tsc` limpio.
- Pendiente: una prueba de punta a punta desde el panel publicado.

## Decisiones
- Solo `data:` y no URL http: el gateway descarga URLs, y una URL remota que
  llega por la ruta sería un SSRF hacia la red del VPS.
- Una imagen por mensaje: el caso real es "mira este comprobante", y el tope
  mantiene el cuerpo pequeño y la latencia predecible.
- 1600 px y JPEG 0,82: suficiente para leer una cifra y una referencia, y deja
  el base64 en cientos de KB.
