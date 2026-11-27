# Contexto del proyecto: negocios locales de Onlinefreedom

Léelo antes de trabajar. Lo escribió Claude (claude.ai) el 27-nov-2026 para que Claude Code
siga el proyecto en la laptop de Julio sin perder el hilo.

## Quién y qué
- Julio (Saltillo, Coah.) arma para negocios locales: sitio web + CRM (este repo, WaCRM
  adaptado) + agente de WhatsApp con IA. Su agencia se llama Onlinefreedom.
- Cliente demo principal: **Doña Miriam**, comida cubana casera por encargo. Un menú fijo por
  día de lunes a sábado; charola $200, anticipo $100, extras $40; se recoge en Dolores
  Hidalgo 124, Col. Guanajuato Oriente, de 12 a 3. Miriam es una señora mayor con Android:
  todo lo que ella use debe ser muy simple.
- Otro demo: AP Suministros (proveedor industrial; rama `ap-suministros`).

## Reglas de trabajo (de Julio)
- Contestar siempre en español de México. Sin emojis en interfaces ni textos.
- Cualquier cambio a un prompt de agente pasa por la skill **prompt-crafter-pro**: puntajes,
  versiones V1 y V2, casos de prueba, y Julio elige cuál se aplica.
- Commit y push solo con su aprobación. Preguntar antes de borrar datos o de cambios
  irreversibles o públicos.
- `master` es de **Remesas Ya** (otro negocio): no se toca. Tampoco su Supabase, su WhatsApp
  ni su agente "Cerebro" sin aprobación explícita.
- Una base de Supabase por negocio. No inventar reseñas, precios ni datos del cliente.
- Julio escribe él mismo contraseñas, llaves y tokens. Nunca guardar secretos ni datos
  bancarios en el repo (los datos de pago de Miriam viven solo en `bot_config` de Supabase).

## Ramas de este repo
| Rama | Qué es |
|---|---|
| `crm-base-sencillo` | Base del CRM para clientes nuevos. Aquí va lo reutilizable. |
| `dona-miriam` | CRM de Miriam en vivo (Vercel lo publica solo al hacer push): https://crm-dona-miriam.vercel.app. Hoy igual a `crm-base-sencillo` en código de la app. |
| `onlinefreedom` | CRM propio de Onlinefreedom. |
| `ap-suministros` | CRM de AP Suministros. |
| `master` | Remesas Ya. No tocar. |

Ojo: este repo usa una versión de Next.js con cambios grandes; ver `AGENTS.md`.

## Doña Miriam: piezas y dónde viven
- **Supabase** proyecto `encargos-dona-miriam`, ref `mltjlslvbhwegnafdswf`. Cuenta del CRM
  (account_id) `ff7a0fa1-1338-439d-8b04-baae18232f94`. Migraciones en `supabase/migrations/`;
  las del bot son `338_bot_mesero.sql` (bot_menu, bot_apartar, bot_precios, bot_ficha,
  bot_config, pasar a humano, cerrar). Se registran en la tabla `public._instalacion`.
- **Menú** (tablas `menu_config`, `menu_items`): 20 platillos agrupados en carne, arroz,
  potaje, ensalada, vianda y extra, cada uno con sus días y su foto (`foto_url`, fotos de la
  página). Es la única fuente para el CRM, la página y el bot.
- **Página**: repo `hmartinezenzona-rgb/sitio-dona-miriam` → Cloudflare Pages,
  https://donamiriam.pages.dev (rama `main`; `crm-nuevo` es vista previa; no comparten
  historia: se publica copiando los archivos de `crm-nuevo` a `main`). Lee el menú con la
  RPC pública `sitio_datos(p_account)` y manda encargos con `encargo_web`.
- **Bot "mesero" de WhatsApp** en n8n (https://automatizaciones-n8n.ttjgax.easypanel.host),
  workflow "Mesero de WhatsApp — Doña Miriam", id `QA127gNkBGWgpy3j`, activo. Modelo
  DeepSeek (credencial deep-freedom). Herramientas: ver_menu, apartar_encargo, nota_interna,
  pasar_a_humano, cerrar_chat.
  - Copia en el repo: `n8n/plantilla-agente/mesero/`. Prompt activo: **`prompt-v4.md`**
    (más conversador: sabe qué es cada platillo, reconoce al cliente que vuelve, varía
    frases). Configuración por negocio: `config-dona-miriam.json` (en el repo con datos de
    pago de ejemplo; la real está en `bot_config`).
  - El nodo "Contar preguntas" descarta respuestas que solo son una marca como `[FIN]` o
    `[SIN_RESPUESTA]`.
- **WhatsApp de prueba** (Meta, app "Doña Miriam pruebas"): número de prueba +1 555 193 6087.
  Es el mismo número de prueba de la app de Julio "Onlinefreedom CRM pruebas 2": mientras se
  prueba a Miriam, en la app de Julio el campo "messages" del webhook está APAGADO. Hay que
  volver a prenderlo al terminar.

## Plantilla de agente para otros negocios
`n8n/plantilla-agente/`: `prompt.md` (reglas comunes), `config-*.json` (lo de cada
negocio), `flujo-plantilla.json`, `flujo-onlinefreedom.json`. El 25-nov se agregó la regla de
formato para WhatsApp: bloques cortos separados por un renglón en blanco, un dato por
renglón, negritas en precios, fechas y etiquetas (nunca en números de cuenta), una sola
pregunta en su propio renglón al final.

## Lo que Julio ya decidió sobre cómo deben conversar los bots
- Natural, no robótico, y fácil de leer. Pocos mensajes (Meta cobra por mensaje). Lo fijo es
  el dato, no la frase.
- No presionar la compra ("¿Le aparto alguna?" le suena insistente). Primero entender qué
  quiere quien escribe antes de mandar el menú. Callarse cuando el mensaje no pide respuesta.
- El bot nunca confirma pagos: pasa el comprobante a Miriam y ella lo marca en el CRM.
- El mesero debe poder cancelar o cambiar encargos mientras no estén pagados.
- Julio probó el mesero en **Parlant** en su laptop (por consola) y le gustó más que el de
  n8n; quiere aprovechar todo Parlant y poner un tope de gasto visible por plática. Ver los
  docs del proyecto en claude.ai: `parlant-decision.md` e `investigacion-parlant.md`.

## Pendientes
1. Seguir probando el mesero (cliente nuevo, cliente que vuelve, foto de comprobante,
   cambio o cancelación, día lleno) y decidir n8n o Parlant.
2. Confirmar con Miriam la lista de qué es cada platillo (`platica` en `bot_config`; ver
   `mesero/mejora-platica/platica.txt`), sobre todo el mojo.
3. Al terminar las pruebas: borrar encargos y chats de prueba y volver a prender "messages"
   en la app de Julio.
4. Número real de Miriam: coexistencia con Zernio.
5. Dominio para Miriam (donamiriam.com estaba libre; comprarlo a nombre de ella).

## Herramientas que conviene conectar en Claude Code
En claude.ai los cambios a Supabase y n8n se hacían desde el Chrome de Julio. En la laptop,
Claude Code necesita sus MCP: Supabase (con acceso a la cuenta donde está Miriam), n8n y,
si se quiere, 21st.dev para componentes de interfaz.
