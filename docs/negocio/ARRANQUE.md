# Arranque en frío — léeme primero

Si estás retomando este proyecto en una sesión nueva: **empieza por aquí**, luego
`PENDIENTES.md`. Con esos dos tienes todo.

---

## LO PRIMERO: el modelo del agente NO debe pensar

El agente usa el nodo **de la comunidad** `n8n-nodes-deepseek-chat-model`
("DeepSeek sin pensamiento"), con `thinkingEnabled = false`.

**No lo cambies al nodo oficial de DeepSeek.** Con el oficial, cualquier turno
en que el agente use **dos herramientas** muere y el cliente no recibe nada — y
eso pasa con la pregunta más común del negocio (*"¿a cómo está el cambio? ¿y
cuánto llega con 30 mil?"*).

Tampoco sirve GPT-5.3: **se inventa las tasas** en vez de llamar a las
herramientas. Detalle completo en `12-el-modelo-no-debe-pensar.md`.

---

## Qué es esto en una frase

**Remesas Ya**: envíos de dinero de Guyana a Cuba por WhatsApp, atendidos por un
agente automático llamado **el Cerebro** que vive en n8n, con **WaCRM** como CRM
y **Supabase** como base de datos.

---

## Accesos — dónde está cada cosa

Ninguna credencial se pide por el chat: todas viven en ficheros del disco.

| Sistema | Cómo | Detalle |
|---|---|---|
| **Supabase** | MCP directo | Proyecto `hqztotshnlzaiziwjyzh`. Funciona sin más |
| **n8n** | `curl` + `~/.n8n-api-key` | Cabecera `X-N8N-API-KEY`. **El MCP de n8n no sirve** para estos workflows: da "not available in MCP" |
| **GitHub** | `curl` + `~/.github-token` | Scope `repo`. **El MCP de GitHub es de SOLO LECTURA** — para escribir, `curl` |
| **Telegram** | `curl` + `~/.telegram-token` y `~/.telegram-chat-id` | Solo de ida: puedo escribirle a Hermes, sus mensajes no me llegan |
| **Firma del webhook** | `~/.cerebro-secret` | Para mandar mensajes de prueba al Cerebro |

**Todas rotadas.** La **API key de n8n** y el **PAT de GitHub** se rotaron el
**10-ago** y las viejas quedaron revocadas: eran las dos últimas que se habían
escrito en una conversación. Ya no queda ningún secreto expuesto.

> **Si hay que volver a rotar:** genera la nueva primero, escribe el fichero, y
> **revoca la vieja solo cuando esté verificado**. Rotar corta el acceso —el de
> GitHub es por donde va el buzón de Hermes— y con la vieja aún viva un fallo se
> arregla en un minuto; sin ella, hay que regenerar a ciegas.

---

## Cómo está organizado n8n

**Carpeta del proyecto: `wacrm_proyect`** (`XceCmnuUDs8tied6`), en el proyecto
personal `g3aVDNWrtfviu0yO`. Con cinco subcarpetas, una por área:

```
wacrm_proyect          XceCmnuUDs8tied6
  ├── cerebro          p6RbPIoavLwfjxw3   Cerebro v2, manejador de errores v2, cron de reintentos
  ├── ingesta          S0ZwqJ6JL7VhaWcH   los dos buzones MMG y la carga historica
  ├── vigilante        OhA4TyY92sqqbjgu   mensajes rechazados, promociones de Etecsa
  ├── crm              jyVTx1EvmmJsnROS   notificar por etapa, abandonos, zombis, tools
  └── legado           UbLJkV6QH5iFRUrM   Cerebro v1, manejador v1, Error Handler viejo
```

**Las subcarpetas se llaman igual que las etiquetas**, a propósito: la carpeta
es para navegar en la UI y la etiqueta para filtrar y para lo que se hace por
API. Al crear un workflow nuevo del proyecto, ponerle sus etiquetas por API
(eso sí se puede) y moverlo a su carpeta a mano.

> **Las carpetas SOLO se manejan a mano, desde el navegador.** Ni la API
> pública (`/api/v1/folders` → 404, y el workflow no expone `parentFolderId`)
> ni `update_workflow` del MCP tienen operación para mover. La API interna
> (`/rest/…`) va por cookie de sesión y **rechaza la API key con 401**.
> Para mover un workflow a la carpeta hay que arrastrarlo en la UI.

Por eso la organización que sí se puede mantener por API son las **etiquetas**.
Se complementan con la carpeta: la carpeta agrupa, las etiquetas permiten
filtrar por función dentro.

Cada workflow del proyecto lleva `remesas-ya` **más** una etiqueta de función.
Así se filtra por proyecto completo o por área:

| Etiqueta | Qué agrupa |
|---|---|
| `remesas-ya` | **todo** lo del proyecto — 16 workflows |
| `cerebro` | Cerebro v2, manejador de errores v2, cron de reintentos |
| `ingesta` | los dos buzones de correo MMG y la carga histórica |
| `vigilante` | mensajes rechazados, promociones de Etecsa |
| `crm` | notificar por etapa, limpieza de abandonos, cierre de zombis, tools |
| `legado` | Cerebro v1, manejador v1, Error Handler viejo, carga histórica |

Lo que **no** lleva etiqueta es todo lo demás: hay **121 workflows en la
instancia y solo 16 son de este proyecto**. El resto son pruebas, plantillas
descargadas y duplicados (`My workflow 1-6`, `trash`, ocho copias de
`Flujo Maestro - Remesas Ya`…). Se dejaron sin tocar a propósito: no molestan y
borrar en masa es un riesgo que no compensa.

> **CUIDADO CON LOS NOMBRES: dos workflows de PRODUCCIÓN se llaman
> "COPIA DE PRUEBA".**
>
> ```
> g3UgayrNlXBXZgnr  "Manejador de errores del Cerebro v2 (Fase 1) - COPIA DE PRUEBA"
> VV3TdssAm9fqC4PM  "Reintento de conversaciones atascadas v2 (Fase 1) - COPIA DE PRUEBA"
> ```
>
> **Los dos son producción.** El nombre sale en las alertas, así que llega un
> aviso que dice *"FALLO EN EL CEREBRO — Workflow: … COPIA DE PRUEBA"* y quien
> lo lea puede ignorarlo pensando que no es real. Guiarse por los IDs, nunca
> por el nombre.

### Los dos manejadores de errores — no es duplicación

Cada uno cubre workflows distintos, así que **nadie recibe dos alertas del
mismo fallo**:

| Manejador | Cubre |
|---|---|
| `g3UgayrNlXBXZgnr` (v2) | Cerebro v2 y cron de reintentos |
| `Gk0RbqK2Msp3aih3` (v1) | Cierre de zombis, notificar por etapa, y 3 legado |

Había un tercero, **`X3BVRpVfxVasMkmT` (`Error Handler - Remesas Ya`), y se
desactivó el 9-ago.** Ningún workflow activo lo usaba. Sí lo referencian dos
copias viejas de `Flujo Maestro - Remesas Ya`, **pero están apagadas**: si
alguna vez se reactivara una de ellas, se quedaría sin manejador de errores.
Copia en `ROLLBACK-error-handler-huerfano.json`.

> **Al desactivar un manejador, mirar TODOS los workflows, no solo los
> activos.** La primera comprobación filtró por activos y dio "no lo
> referencia nadie", que era falso.

**Comprobación para después de tocar cualquier manejador** — ningún workflow
activo debe apuntar a uno apagado o inexistente:

```bash
# para cada activo con settings.errorWorkflow, verificar que ese ID
# existe y está activo. Hoy: 13 activos, ninguno huérfano.
```

---

## IDs que hacen falta constantemente

```
n8n
  Cerebro v2 (PRODUCCIÓN) ....... T3v07IQqtMs6AKJ4   path: wacrm-cerebro
  Cerebro v1 (rollback, parado) . NgnTPBVzO1m0NPYz
  Manejador de errores v2 ....... g3UgayrNlXBXZgnr
  Cron de reintentos v2 ......... VV3TdssAm9fqC4PM
  Notificador por etapa ......... wGud0KGR6eMqqfMQ
  Vigilante msgs rechazados ..... rNN0LdHGTYUDOTfB   cada 5 min
  Vigilante promos de Etecsa .... vk6aEa4bOZtl5xSz   cada 12 h
  Vigilante ingesta de MMG ...... NiibUBRtOlOppmY4   cada 10 min
  Vigilante depositos sin cruzar  bTwsEJsmoAzsuOxm   cada 10 min
  Vigilante chats atascados ..... 0nEQnuPE15UgRudW   cada 5 min
  Vigilante mensajes perdidos ... HVNAIc8otXHejsw4   cada 10 min

Credenciales de DeepSeek (OJO, son dos y parecidas):
  deepseekApi  2joB4BwDAiyuSMcC  "deekpseek comunidad"  <- LA QUE SE USA
  deepSeekApi  f0K27ImOFO3QdL34  "DeepSeek account"     (del nodo oficial, sin usar)

  Ingesta correo AGENTE ......... 0ErvmKgcon3lMeYb   asunto CASH_IN_TO_AGENT_OK_RECEIVER
  Ingesta correo CUENTA MMG ..... 4joVPN9jiXe0Z77Q   asunto "Payment Received" (app)

Credencial de WaCRM en n8n ...... p8EN42saerBDHZwI  "WaCRM API" (httpHeaderAuth)
Credencial de Postgres .......... S2CallLPSjzbVXN4  "Supabase Account"

Supabase ........................ hqztotshnlzaiziwjyzh
Pipeline de remesas ............. 78220927-0745-45a8-ba08-a1b33734dbf1
  Solicitada .................... 96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109
  Por verificar ................. 3cf01654-cd27-47c1-ac92-62abf5435751
  Lista para transferir ......... f5cf87f8-b570-4d71-b6ea-a3cafd458c63
  Entregada ..................... 1b36b34c-1bf1-4095-9a86-5ec5ff945d2b
  Incidencia .................... da7b3e24-9222-4150-8be8-d7f7378e16aa

Pipeline de SERVICIOS (vacío) ... 37f91872-6eb6-40d4-b8e6-1017053b9bf0
  Solicitado / Pagado / En proceso / Entregado / Incidencia

Cuentas de deposito (OJO, son dos y NO son intercambiables):
  Agente MMG ..... Osmany Pozo ...... 6762167   <- LA POR DEFECTO (26 de 27 depositos)
  Pay Merchant ... Osmany Services ... 6990225   solo si el cliente dice 'app'

Cuenta (account_id) ............. 465fb4ce-33b6-4473-ad2c-42818772f587
Agente al que se asigna .......... 377b0c8c-c025-46ff-8088-7a929080831e
Los 3 usuarios que reciben avisos:
  e3c7943d-b2fa-4c53-ae2f-406f1533ed47
  5c4d16fd-1530-4023-8119-b58e04cc815f
  ca797265-a1b3-43f7-9d9f-68c15d1f4780

Conversación de PRUEBAS ......... 40e6ab76-9597-4a2b-bf18-96450476a8bb
                                  (+5219624564224, es el número de Humberto)

GitHub .......................... hmartinezenzona-rgb/wacrm  (rama master, PÚBLICO)
WaCRM en producción ............. https://wacrm.onlinefreedom.site
```

> **HORAS: cuidado, hay tres husos en juego.**
> El **negocio está en Guyana (UTC-4)**, **Humberto está en México (UTC-6)** y
> **la base guarda todo en UTC**. Un "hoy" mal calculado descuadra los informes
> y hace decir tonterías tipo "son las dos de la mañana" cuando allí son las
> ocho de la tarde. Las vistas de contabilidad usan **`America/Guyana`**, que es
> el calendario del negocio.

---

## Cómo se trabaja con Hermes

**Hermes** es otro agente, en el VPS, que lleva el código de WaCRM (Next.js).
Yo llevo el Cerebro (n8n) y la base de datos. Ninguno toca lo del otro.

**El buzón** — `coordinacion/` en el repo. Un fichero por mensaje:

```
coordinacion/AAAA-MM-DD-HHMM-quien-asunto.md
```

Con cabecera `De:`, `Para:`, `Asunto:`, `Responde-a:`, `Estado:`. Nadie edita el
fichero de otro: se contesta creando uno nuevo. La convención está en
`coordinacion/README.md`.

**Cuidado con esto:** para leer los comentarios de una issue hace falta **otro
endpoint** que el del cuerpo:

```
/repos/.../issues/1            <- solo el cuerpo
/repos/.../issues/1/comments   <- los comentarios
```

**Telegram** sirve para avisarle de que hay algo nuevo. Él tiene un vigilante
que mira el buzón cada 30 segundos.

**Él no puede escribir en las issues** (su deploy key solo habla git), así que
responde en el buzón o vía Humberto.

---

## Cómo se despliega

**El Cerebro (n8n):** para los **nodos Code** ya NO se despliega a mano —
se pasa por el banco, que baja el nodo de producción, lo compara con el
candidato sobre los 371 mensajes reales y solo entonces sube:

```bash
cd ~/cerebro-fase1/pruebas
python3 banco.py --nodo "Normalizar formato" \
                 --candidato candidato-normalizar-formato.js \
                 --casos casos-normalizar-formato.json [--desplegar]
```

Ver `23-el-banco-de-pruebas.md`. Para lo demás (conexiones, prompt, nodos que
no son Code): bajar el workflow con `curl`, parchearlo con Python, subirlo con
`PUT`, **guardando siempre una copia antes** — hay varios
`ROLLBACK-v2-antes-*.json` de ejemplo.

> **El MCP de GitHub NO puede escribir** (`403 Resource not accessible by
> integration`). Para subir un fichero al repo hay que ir por la API con el PAT
> de `~/.github-token`, que es lo que hace `PUT /repos/.../contents/<ruta>`
> mandando el contenido en base64 y, si el fichero ya existe, su `sha`.

**Las migraciones de base de datos** se aplican con el MCP de Supabase y
**además** se guardan como fichero: las mías numeradas van al repo de WaCRM en
`supabase/migrations/` (037, 038, 039…), para que el repo refleje la realidad.
El fichero se marca siempre con «ya aplicada, no la ejecutes».

**WaCRM:** el código lo escribe Hermes, pero **el `Deploy` lo dispara HUMBERTO a
mano** en Actions. Construye en el CI → `rsync -az --delete` al VPS →
`pm2-restart-wacrm`. **Nunca compilar en el VPS**: tiene 1 GB de RAM y `tsc` lo
tumba (ya pasó, y tiró el servicio).

> ### UN COMMIT NO ES UN DESPLIEGUE
>
> Pasó el 9-ago y costó un rato de confusión: Hermes subió dos commits, el
> `Deploy` salió **entre los dos**, y la pantalla del segundo se quedó fuera.
> `GET /resumen` devolvía 404 mientras el código estaba en `master`.
>
> **Antes de decir que algo está en producción, comprobarlo contra el
> servidor**, no contra el repo:
>
> ```bash
> curl -s -o /dev/null -w "%{http_code}\n" https://wacrm.onlinefreedom.site/<ruta>
> # y qué commit desplegó de verdad:
> curl -s -H "Authorization: token $T" \
>   "https://api.github.com/repos/hmartinezenzona-rgb/wacrm/actions/runs?per_page=10" \
>   | python3 -c "import json,sys; [print(r['created_at'], r['head_sha'][:8], r['conclusion']) for r in json.load(sys.stdin)['workflow_runs'] if r['name']=='Deploy']"
> ```
>
> Y **el navegador puede seguir sirviendo el JS viejo**: `/sounds/*` y el
> catch-all van con `s-maxage=300, stale-while-revalidate=86400`. Si algo
> "no cambia", pedir un `Ctrl+Shift+R` antes de buscar el fallo en el código.

El pipeline está bien, pero tiene tres detalles que costaron sangre y no hay que
tocar: `cp -a .next/standalone/.` con **punto** y no con asterisco (el glob se
salta los ficheros ocultos y el servidor se cae en la primera página),
`cp -r public deploy/public` para los estáticos, y `--exclude=.env.local` para
que el `--delete` no se lleve la configuración.

**TRAMPA DE n8n:** al cambiar la **estructura** de un workflow activo por API
—añadir nodos o reconectar— n8n sigue ejecutando la versión que tiene en
memoria. Los cambios de parámetros (un prompt, una consulta) sí se aplican
solos; los estructurales, no. Ya provocó dar por buena una prueba que corría
con el flujo viejo. Después de tocar nodos o conexiones, **siempre**:

```bash
curl -s -X POST "$B/api/v1/workflows/$ID/deactivate" -H "X-N8N-API-KEY: $K"
sleep 2
curl -s -X POST "$B/api/v1/workflows/$ID/activate"   -H "X-N8N-API-KEY: $K"
```

Y comprobar en la ejecución que los nodos nuevos **aparecen**, no solo que el
resultado parezca correcto.

**No hay entorno de pruebas.** Todo va contra producción. El negocio abre **L-S
de 9:00 a 17:00 hora de Guyana**: fuera de eso es cuando se despliega lo que no
sea urgente. Un despliegue de WaCRM reinicia el servicio unos segundos, y WaCRM
es quien recibe los webhooks de WhatsApp.

---

## Cómo se prueba un cambio del agente

```bash
B=https://automatizaciones-n8n.ttjgax.easypanel.host
SEC=$(tr -d '\n\r ' < ~/.cerebro-secret)
CONV=40e6ab76-9597-4a2b-bf18-96450476a8bb
W="wamid.PRUEBA.$(date +%s)"
CUERPO="{\"event\":\"message.received\",\"data\":{\"conversation_id\":\"$CONV\",\"content_type\":\"text\",\"text\":\"lo que sea\",\"whatsapp_message_id\":\"$W\"}}"
TS=$(date +%s)
F=$(printf '%s' "$TS.$CUERPO" | openssl dgst -sha256 -hmac "$SEC" -r | cut -d' ' -f1)
curl -s -X POST "$B/webhook/wacrm-cerebro" \
  -H 'Content-Type: application/json' \
  -H "X-Cerebro-Timestamp: $TS" -H "X-Cerebro-Signature: sha256=$F" \
  --data-binary "$CUERPO"
```

Tarda unos 45 segundos: hay un debounce de 12 s más el agente. Luego se mira la
ejecución en n8n y la respuesta en `messages`.

**Ojo:** esto va directo al Cerebro y **no pasa por WaCRM**, así que el mensaje
del cliente no queda en `messages`. Para probar la cadena completa hace falta un
WhatsApp de verdad desde el número de pruebas.

**ANTES DE TOCAR EL PROMPT, lee `11-lenguaje-deliberativo-rompe-deepseek.md`.**
Cualquier frase que le pida al modelo **decidir, valorar, comparar o
interpretar** cuando hay herramientas de por medio activa el modo pensamiento de
DeepSeek, y a partir del turno siguiente **la conversación se rompe** con
`reasoning_content ... must be passed back`. Ha pasado tres veces: 1-ago, 5-ago
y 9-ago. Se escribe como **mapeo plano** (palabra → herramienta), nunca en prosa.

**La prueba que nunca se salta:** después de cualquier cambio en el prompt,
comprobar que una consulta de remesa normal sigue respondiendo igual. Lo nuevo
no vale nada si degrada lo que ya funciona.

### Probar cosas de la base sin dejar rastro

Dos trucos que han salido muy rentables y conviene reutilizar.

**Modo simulación.** `cerebro_cruzar_deposito` tiene un último parámetro
`p_simular`: calcula el veredicto y lo devuelve **sin escribir nada ni avisar a
nadie**. Sirve para probar contra casos reales de producción. Cuando escribas
una función que toque dinero, ponle uno igual.

**El bloque que se revierte solo.** Para probar disparadores hay que provocar el
cambio de verdad. Un `DO $$ … RAISE EXCEPTION … $$` hace el cambio, comprueba el
efecto y **revierte la transacción entera** al lanzar, incluidos los `INSERT` que
hizo el disparador. El resultado llega en el texto del error:

```sql
DO $$
DECLARE v_n int;
BEGIN
  UPDATE deals SET stage_id = '<incidencia>' WHERE id = '<un deal>';
  SELECT count(*) INTO v_n FROM notifications WHERE type='deal_incidencia';
  RAISE EXCEPTION 'avisos creados: % (todo revertido)', v_n;
END $$;
```

Ojo: si la transacción usa `net.http_post`, el rollback **también** cancela la
petición, así que no se manda ningún WhatsApp de mentira. Eso es a favor.

---

## Vigilancia

`05-vigilancia-diaria.sql` da el estado en 30 segundos. Lo importante:

```sql
SELECT count(*) FROM session_events WHERE processing_status <> 'completed';  -- debe ser 0
SELECT count(*) FROM session_events WHERE processing_status = 'processing';  -- debe ser 0
SELECT * FROM cerebro_alertas WHERE ultimo > now() - interval '24 hours';

-- Mensajes que WhatsApp rechazo. El cron avisa en el CRM, pero conviene mirarlo.
SELECT status, count(*) FROM messages
 WHERE created_at > now() - interval '24 hours' GROUP BY status;

-- LO QUE DE VERDAD ES TRABAJO PENDIENTE: alguien mando su comprobante y no
-- se le pudo cruzar. Aqui hay un cliente esperando.
SELECT d.id, d.value, d.created_at,
       round(EXTRACT(epoch FROM (now()-d.created_at))/3600,1) AS horas_esperando,
       substring(d.notes from 'Ref: ([0-9]+)') AS ref_leida
  FROM deals d
 WHERE d.stage_id = '3cf01654-cd27-47c1-ac92-62abf5435751'   -- Por verificar
   AND d.notes LIKE '%Ref: %'
 ORDER BY d.created_at;

-- Depositos que se dieron por buenos sin que la referencia cuadrara exacta:
-- hay que confirmarlos a ojo contra el comprobante.
SELECT id, value, updated_at FROM deals
 WHERE notes LIKE '%COINCIDENCIA APROXIMADA%' ORDER BY updated_at DESC;
```

**Un depósito sin reclamar NO es trabajo pendiente.** La tabla `depositos_mmg`
es la bandeja del correo de MMG, no una lista de tareas. Un depósito que nadie
ha reclamado puede ser una recarga de saldo del propio Osmany, un cobro ajeno al
bot, o un cliente que todavía no ha mandado su captura — y en los tres casos la
acción correcta es **ninguna**. Un depósito solo importa cuando llega un
comprobante que lo reclama. Por eso la consulta de arriba mide los **envíos que
esperan verificación**, no los depósitos sueltos.

**La trampa de esta base de datos:** `profiles` tiene **dos** columnas de
identidad, `id` y `user_id`. Lo que apunta a `auth.users` —y por tanto lo que
vale para `notifications.user_id`— es **`user_id`**. Usar `id` viola la clave
ajena; y como los disparadores se tragan los errores para no tumbar el flujo del
dinero, **falla en silencio**. Ya me costó un rato una vez.

---

## Rollback del Cerebro — 30 segundos

1. Desactivar `T3v07IQqtMs6AKJ4`
2. Activar `NgnTPBVzO1m0NPYz`
3. `UPDATE session_events SET procesado=false WHERE processing_status IN ('processing','retry_wait');`

**No quitar el `?secret=` de WaCRM** mientras el v1 siga siendo el rollback: es
lo único que lo mantiene utilizable.

---

## Los documentos

| Fichero | Qué tiene |
|---|---|
| `PENDIENTES.md` | **Lo que falta**, ordenado por lo que más duele |
| `FASES-ANALISIS-COMPLETO.md` | Balance de las 3 fases del spec de GPT contra lo que hay |
| `PLAN-2E-outbox.md` | **Leer antes de tocar el outbox.** Las 3 fases y sus riesgos |
| `RESPUESTAS-OSMANY-servicios.md` | **Cómo funciona el negocio, en sus palabras.** Precios, costes y reglas |
| `PEDIR-A-OSMANY-contabilidad.md` | Lo que falta preguntarle para cerrar la contabilidad |
| `13-normalizador-de-formato.md` | Separa en párrafos lo que el agente manda de un tirón (ver también el `20-`) |
| `14-lo-que-se-le-dice-al-cliente-sale-del-sql.md` | **Leer antes de tocar el `Decisor`.** El bot no confirma lo que el SQL no confirmó |
| `15-la-via-de-deposito-por-defecto.md` | Las dos cuentas de depósito. Si el cliente no elige, es **Agente 6762167** |
| `16-fugas-de-razonamiento-y-bucles.md` | El filtro que impide que el razonamiento del modelo llegue al cliente, y el cortacircuitos de bucles |
| `17-no-prometer-la-transferencia-sin-beneficiario.md` | **Leer antes de tocar el notificador por etapa.** Y cómo se leen las conversaciones: con su fecha delante |
| `18-dos-caidas-silenciosas.md` | **Leer antes de tocar una consulta de un workflow.** La ingesta caída 4 h y el Cerebro roto 27 min |
| `19-que-se-le-pide-al-cliente.md` | **Leer antes de tocar el `Decisor`.** Qué se le pide y qué NO se le promete, y cómo se prueban las ramas de verdad |
| `20-el-normalizador-y-sus-dos-huecos.md` | El formato de las respuestas. **El notificador por etapa NO pasa por el normalizador** |
| `21-vigilante-de-la-ingesta.md` | Por qué vigila la credencial y no el volumen de depósitos |
| `040`…`044` | Fase 2: operaciones, escritura dual, beneficiarios, log de tools |
| `045_purga_de_logs.sql` | Purga semanal con `pg_cron` |
| `046_pipeline_servicios.sql` | Pipeline `Servicios` y `service_type` |
| `047`…`050` | Promociones de Etecsa: detección, confirmación y aviso previo |
| `051_message_outbox.sql` | Outbox — **solo la fase 1 está aplicada** |
| `ARRANQUE.md` | Esto |
| `FASE2-ANALISIS.md` | Análisis de la Fase 2: dependencias, 6 tramos, riesgos |
| `SERVICIOS-tramo1.md` | Los servicios que no son remesas |
| `PREGUNTAS-OSMANY-servicios.md` | 37 preguntas para diseñar los combos |
| `PENDIENTE-bot-callado-en-chats-ocultos.md` | Especificado, sin hacer |
| `01`…`04-*.sql` | Migraciones de la Fase 1 y el punto 10 |
| `06-cruce-aproximado.sql` | Cruce de depósitos: plan B y control de antigüedad |
| `038_notificacion_deal_incidencia.sql` | Aviso en el CRM al caer en Incidencia |
| `039_vigilante_mensajes_fallidos.sql` | Cron de mensajes que WhatsApp rechaza |
| `05-vigilancia-diaria.sql` | Consultas de salud |
| `10-vision-doble-lectura.md` | Fotos giradas: **cuatro** lecturas y un árbitro |
| `11-lenguaje-deliberativo-rompe-deepseek.md` | **Leer antes de tocar el prompt** |
| `12-el-modelo-no-debe-pensar.md` | **Leer antes de tocar el modelo** |
| `20-el-normalizador-y-sus-tres-huecos.md` | Por qué las respuestas se leen como se leen |
| `22-el-skip-y-el-orden-de-la-tuberia.md` | **El orden de los nodos decide, no solo el código** |
| `23-el-banco-de-pruebas.md` | 🧪 **`pruebas/banco.py` — nada se despliega a mano** |
| `ROLLBACK-*.json` | Copias de los workflows antes de cada cambio |
| `GUIA-HERMES-*.md` | Guías que se le pasaron a Hermes |
| `GUIA-HERMES-webhook-tira-mensajes.md` | 🔴 **Mensajes de clientes que nunca llegan al CRM** |
| `PLAN-vigilante-mensajes-perdidos.md` | Tercer vigilante — **especificado, espera la tabla de Hermes** |
| `PEDIR-A-OSMANY-depositos-sin-dueno.md` | Ocho depósitos que hay que triangular con Osmany |

Las tres migraciones numeradas están **aplicadas en producción** y copiadas al
repo de WaCRM. Cada una lleva dentro cómo se probó y cómo se revierte.

---

## Dónde está el proyecto — foto del 9-ago-2026

**Lo que funciona hoy, sin intervención humana:**

- El **Cerebro** atiende remesas de punta a punta: cotiza, registra beneficiario,
  lee el comprobante, lo cruza con el correo de MMG y avisa al cliente
- **Cinco servicios** además de remesas. El bot **cierra solo** visa y
  traducción; **recargas desde el 13-ago**; combos y México informan y derivan
- **Fase 2 casi entera**: estado canónico por `operation_id`, beneficiarios
  auditados, log de llamadas, y el outbox en sombra
- Cuatro **vigilantes**: mensajes rechazados, promociones de Etecsa, reintentos
  y cierre de zombis
- **Contabilidad**: volumen por día/semana/mes e historial, en `/resumen` del CRM

**Lo que NO existe todavía:**

- **Ganancia** — falta el coste del CUP. Es la única pregunta abierta a Osmany
- **Pipeline de combos** — un comprobante de combo hoy entraría como remesa
- **Entorno de pruebas** — todo va contra producción
- **Fases 2E (2 y 3) y 2F**

---

## Lo primero que haría al retomar

**1. Salud en un minuto:**

```sql
SELECT count(*) FROM session_events WHERE processing_status <> 'completed'; -- 0
SELECT * FROM cerebro_conciliacion_operaciones;                            -- 0 filas
SELECT * FROM cerebro_outbox_salud;
SELECT valor::timestamptz, now() - valor::timestamptz AS hace
  FROM cerebro_config WHERE clave='promo_etecsa_ultima_revision';          -- < 2 días
```

**2. El buzón**, por si Hermes dejó algo: `coordinacion/` en el repo, ordenado
por nombre; los últimos ficheros son los recientes.

**3. `PENDIENTES.md`** — arriba del todo hay un cuadro de una pantalla con todo
lo abierto y de qué depende cada cosa.

**4. Preguntar por dónde seguir.** No dar por hecho el orden del spec: ver
`FASES-ANALISIS-COMPLETO.md`, donde está por qué no se sigue al pie de la letra.

---

## Cómo se trabaja aquí — lo que ha funcionado

Esto no es relleno: es lo que ha evitado la mayoría de los sustos.

**Una rama que no se ha visto producir un mensaje real no está probada.** Un
dry-run demuestra qué orden le llega al modelo, nunca qué escribe. El 10-ago
tres fallos pasaron todas las comprobaciones previas y solo aparecieron
mandando un mensaje de verdad — uno de ellos era una rama de código
**inalcanzable** que parecía correcta. Ver `19-que-se-le-pide-al-cliente.md`.

**Una consulta de un workflow se valida DENTRO de n8n.** `PREPARE` valida SQL,
pero el nodo hace cosas con el texto antes de enviarlo (y el JSON del workflow
deforma las barras invertidas). Monta un banco aparte con la consulta **copiada
del JSON por programa**, y antes de subir compara que lo desplegado es lo
validado. El 10-ago me salté esto y tumbé el Cerebro 27 minutos.

**Medir antes de decidir.** Casi todas las decisiones buenas del proyecto
salieron de una consulta, no de una intuición: que el cruce fallaba 1 de 13, que
el dashboard estaba 9 veces inflado, que **ningún cliente ha pedido nunca un
envío a México**, que el 41% de los mensajes no llevaban saltos de línea.

**Instrumentar en vez de razonar, cuando algo se resiste.** Los cuatro fallos
del CRM del 9-ago no se resolvieron pensando:

| Fallo | Lo que lo resolvió |
|---|---|
| El tono no se oía | `ffmpeg volumedetect` sobre el fichero servido |
| El botón no aparecía | leer el `useEffect` y ver el `[]` |
| Sonaba sin motivo | un espía sobre `HTMLMediaElement.play` |
| La pantalla no salía | comparar la hora del deploy con la del commit |

Si dos diagnósticos seguidos fallan, deja de discutir con el síntoma y ponle un
instrumento.

**Probar con datos reales, no inventados.** El normalizador de formato rompió
mensajes con cifras **dos veces** antes de funcionar, y las dos se vieron
pasándole mensajes de verdad. Con textos de ejemplo habría pasado la revisión.

**Leer las conversaciones con su fecha delante.** No se empata una conversación
de hace tres días con una de hoy: el sistema cambia varias veces al día. Filtrar
por `created_at::date` y leerla entera y en orden. El 10-ago esto evitó culpar al
bot de fallos que no cometió — los beneficiarios «creados el 09-08 a las
17:51:55» son el backfill de la `042`, no datos reales de ese momento.

**Verificar antes de afirmar.** Varias veces se dio algo por bueno y estaba mal:
"nadie referencia ese manejador" (era falso, había dos), "las 37 preguntas están
sin responder" (llevaban respondidas un día). Comprobar > recordar.

**No mezclar cambios.** Si algo se rompe, que se sepa qué fue.

**Cuidado con los errores que se tragan solos.** Los disparadores que tocan el
flujo del dinero llevan `EXCEPTION WHEN OTHERS` para que un aviso roto no tumbe
un envío — decisión correcta **y** fuente de fallos invisibles. Si algo "no hace
nada", sospecha de eso antes que del resto. Las redes que lo cubren:
`cerebro_conciliacion_operaciones` y los `RAISE WARNING` en el log de Postgres.

**Nada en horario de negocio** (L-S 9:00-17:00 hora de **Guyana**) salvo urgencia
acordada. El 9-ago se rompió producción una vez y se revirtió en dos minutos sin
que lo viera ningún cliente — porque era domingo. Eso fue suerte además de
diseño.

**Los secretos se generan donde se usan.** Solo viaja la ruta del fichero o una
clave pública, nunca el valor. Ya se aplicó tres veces.

**Lo que cuesta caro conseguir, va al repo.** Las respuestas de Osmany sobre
cómo funciona el negocio vivieron un día entero solo en un chat y estuvieron a
punto de perderse. Ahora están en `docs/negocio/`.
