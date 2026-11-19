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
   - `conocer`: lista ordenada de datos a pedir. Cada uno: `clave` (nombre, negocio o la clave que acepta la RPC), `etiqueta` (cómo aparece en la ficha: Giro, Reto, Llamada…), `pregunta` (qué preguntar, el modelo lo dice con sus palabras), `obligatorio`, `requiere` (claves que deben estar antes)
   - `registro`: `rpc`, `campos` (claves que acepta esa función), `instrucciones`
   - `reglas_extra` y `humano_extra` (listas), `aviso_precio`, `ejemplos` (2 o 3 diálogos cortos)
3. **n8n**: importa `flujo-plantilla.json`, y en el nodo **Configuración** pon `crm_url`, `supabase_url`, `supabase_key` (publicable), `cuenta`, `msg_archivo`, `contexto_audio`, `contexto_foto`. Cambia el `path` del webhook. Asigna las credenciales: llave del CRM (Header Auth `Authorization: Bearer wacrm_live_…`) y OpenAI. Activa.
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
3. **Validador con re-pregunta.** "Contar preguntas" revisa la respuesta; si trae más de una, "Corregir respuesta" (una llamada corta al modelo, temperatura 0) la reescribe con una sola. Solo cuesta tiempo cuando falla.
4. **Red final en el CRM.** `soloUnaPregunta()` en formato-bot deja solo la última si algo se colara.
