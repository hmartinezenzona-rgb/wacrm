# Agente de WhatsApp reutilizable

Un solo diseño de agente para todos los negocios. Lo que cambia de un negocio a otro vive en **datos**, no en el flujo:

| Pieza | Dónde vive | ¿Se toca por negocio? |
|---|---|---|
| Flujo de n8n (juntar mensajes, audios, fotos, anti-abuso, enviar, herramientas) | `flujo-plantilla.json` | No (solo el nodo **Configuración**) |
| Reglas comunes (sonar a persona, formato WhatsApp, una pregunta, saludo, cierre, spam, horario, pasar a humano, no inventar precios) | `prompt.md` (system message del nodo Agente) | No |
| Lo propio del negocio (rol, contexto, qué preguntar, cómo registrar, horario, ejemplos…) | tabla `bot_config` del CRM de ese negocio (migración 322) | Sí |
| Productos / servicios / paquetes con precio | tabla `catalogo` del CRM (pantalla Catálogo/Paquetes) | Sí |
| Qué precios puede decir el agente | se sacan solos del catálogo (`bot_precios`) | Automático |
| Dónde se registra al cliente | función del CRM indicada en `bot_config.registro.rpc` (`diagnostico_solicitar`, `cotizacion_solicitar`, `encargo_web`…) | Se elige |

## Alta de un negocio nuevo (≈ 30 min si su CRM ya existe)

1. **CRM**: el negocio ya tiene su rama de `wacrm`, su Supabase y su Vercel (como AP, Miriam, Onlinefreedom). Aplica la migración `322_agente_reutilizable.sql` (y 321 si quieres ficha, notas, cierre y seguimientos).
2. **bot_config**: copia `config-onlinefreedom.json`, cambia los textos y guárdalo:
   `insert into bot_config (account_id, data) values ('<cuenta>', '<json>') on conflict (account_id) do update set data = excluded.data;`
   Campos:
   - `negocio`, `zona_horaria`, `trato` (tú / usted), `voz` ("una encargada de una cocina económica de Saltillo"), `quien_atiende` ("Miriam", "el equipo")
   - `horario`: `texto`, `dias` (1 = lunes … 7 = domingo), `abre`, `cierra`, `siguiente` ("mañana a partir de las 9")
   - `rol`, `objetivo`, `pasos` (lista), `contexto` (viñetas con todo lo que el agente debe saber)
   - `catalogo_nota` (cómo presentar el catálogo), `fuera_de_catalogo` (qué decir si piden algo que no está)
   - `conocer`: lista ordenada de datos a pedir. Cada uno: `clave` (nombre, negocio o la clave que acepta la RPC), `etiqueta` (cómo aparece en la ficha: Giro, Reto, Llamada…), `pregunta` (qué preguntar, el modelo lo dice con sus palabras), `obligatorio`, `requiere` (claves que deben estar antes), `guardar` (opcional: cómo anotarlo en la ficha, por ejemplo el nombre exacto del paquete)
   - `conocer` también acepta `si` (el dato solo cuenta si otro tiene cierto valor) y `preguntar_si` (se guarda siempre que el cliente lo diga, pero solo se pregunta si se cumple; ej. el día de la llamada).
   - `registro`: `rpc`, `campos` (claves que acepta esa función), `instrucciones`
   - `reglas_extra` y `humano_extra` (listas), `aviso_precio`, `ejemplos` (2 o 3 diálogos cortos)
   - `editor` (opcional): `false` para apagar el editor humanizer en ese negocio. Por defecto está prendido.
2b. **Entrevista** (opcional, migración `328_bot_entrevista.sql`): las preguntas para conocer el negocio del cliente viven en la tabla `bot_entrevista`, NO en el prompt ni en `bot_config`. Copia `entrevista-onlinefreedom.json` y guárdalo:
   `insert into bot_entrevista (account_id, data) values ('<cuenta>', '<json>') on conflict (account_id) do update set data = excluded.data, updated_at = now();`
   Cada pregunta: `clave`, `etiqueta` (línea de la ficha), `pregunta`, `ayuda` (cómo explicarla en palabras sencillas si el cliente no la entiende), `guardar` y `si` opcionales. `modo_etiqueta` es la línea de la ficha donde queda chat / pdf / llamada; `cierre`, qué hacer al terminar.
   Es corta a propósito (7 preguntas): qué vende, nombre-zona-horario, cómo trabaja, cuántos clientes, qué le complica, qué le urge más (una sola) y una pregunta de ese módulo. Lo demás lo asumimos nosotros o se ve en la llamada. La prueba se arma con datos e imágenes de ejemplo; la lista de precios y las fotos del cliente son opcionales y se usan cuando contrata.
   Columnas del tablero (migración 331): renombra en cada cuenta «Diagnóstico agendado» → «Llamada agendada» y «Diagnóstico hecho» → «Entrevista lista». La tarjeta pasa sola a «Entrevista lista» cuando termina la entrevista por chat o con las respuestas del PDF, y a «Llamada agendada» cuando aparta llamada.
   El agente la usa con la herramienta **entrevista** (RPC `bot_entrevista`): en cada mensaje le devuelve lo que ya contestó, la siguiente pregunta con su ayuda y si ya terminó. El extractor también la lee (nodo "Leer entrevista") para guardar las respuestas en la ficha. Si cambias preguntas, actualiza también el PDF (`sitio-onlinefreedom/conozcamos-su-negocio.pdf`).
3. **n8n**: importa `flujo-plantilla.json`, y en el nodo **Configuración** pon `crm_url`, `supabase_url`, `supabase_key` (publicable), `cuenta`, `msg_archivo`, `contexto_audio`, `contexto_foto`. Cambia el `path` del webhook. Asigna las credenciales: llave del CRM (Header Auth `Authorization: Bearer wacrm_live_…`), DeepSeek (credencial del nodo de la comunidad `n8n-nodes-deepseek-chat-model`, tipo deepseekApi: Modelo, Modelo JSON, Modelo texto y Modelo visión) y OpenAI (Transcribir audio, porque DeepSeek no transcribe audio, y el respaldo de visión). Activa.
4. **CRM → n8n**: corre una vez el nodo "Crear webhook en el CRM" (o regístralo por API) para que cada mensaje llegue al flujo.
5. **Seguimientos** (opcional): importa `../onlinefreedom-seguimientos.json` y cambia cuenta, URL y llave.
6. **Probar** con el número de prueba y revisar los chats con la skill `revisar-agente-whatsapp`.

## Cambiar algo de un negocio ya en marcha
- Lo que dice / pregunta / cómo registra → editar su `bot_config` (efecto inmediato, sin tocar n8n).
- Precios → pantalla de catálogo del CRM.
- Una regla que debería valer para TODOS → `prompt.md` y actualizar el nodo Agente en cada flujo.

## Cómo evita hacer dos preguntas (y otros errores) — en capas
Basado en cómo lo resuelven plataformas maduras (patrón "slot filling" de Google CX Agent Studio y los `collect` de Rasa CALM; validadores con re-pregunta de Guardrails AI):
1. **El código decide qué falta, el modelo solo redacta.** El nodo "Qué falta" lee la ficha del CRM y `bot_config.conocer` y le pasa al modelo UN solo "siguiente dato". El modelo nunca ve la lista de preguntas futuras.
2. **Extracción en lote.** Cada vez que el cliente da un dato, el modelo registra todo lo que sabe; así la ficha (el estado) siempre está al día.
3. **Editor humanizer.** Después del agente, "Editor" (DeepSeek, "Modelo JSON") reescribe la respuesta para quitar lo que suena a bot (muletillas, relleno, palabras de folleto), con la `voz` y el `trato` del negocio. "Revisar edición" compara en código el borrador con lo editado: si cambió cifras, links o nombres en negrita, agregó o quitó la pregunta, lo alargó o recortó de más, se manda el borrador original. En la ejecución queda el campo `editor` (editado / sin cambios / descartado: motivo) y el `borrador`.
4. **Validador con re-pregunta.** "Contar preguntas" revisa la respuesta; si trae más de una, "Corregir respuesta" (una llamada corta al modelo, temperatura 0) la reescribe con una sola. Solo cuesta tiempo cuando falla.
5. **Red final en el CRM.** `soloUnaPregunta()` en formato-bot deja solo la última si algo se colara.

## Modelos (desde el 19 nov 2026)
Igual que el Cerebro v2 de Remesas Ya: DeepSeek `deepseek-flash` con el nodo de la comunidad `n8n-nodes-deepseek-chat-model`, pensamiento apagado.
- Modelo (temp 0.3) → Agente.
- Modelo JSON (temp 0.1, respuesta JSON) → Extraer datos y Editor (cadenas "Basic LLM Chain"; su salida es `text`).
- Modelo texto (temp 0) → Corregir respuesta.
- Modelo visión (temp 0) → Ver foto, con respaldo OpenAI gpt-4.1-mini. La foto se baja primero en "Descargar foto" (binario `imagen`).
- Audio: OpenAI `gpt-4o-mini-transcribe`.
- Las cadenas usan plantillas de LangChain: las llaves { } se toman como variables. Por eso los textos de sistema no llevan llaves y a lo que viene del cliente se le quitan.
- CUIDADO con DeepSeek V4: si el prompt le pide deliberar ("piensa", "decide cuál herramienta", "evalúa"), puede ponerse a razonar; razonar + llamar herramienta hace que la API exija reenviar `reasoning_content`, que n8n no conserva, y el agente truena. En `prompt.md` y en `bot_config` nada de lenguaje deliberativo: reglas planas y ejemplos.
