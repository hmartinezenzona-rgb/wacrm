# Remesas Ya — documentación del Cerebro

**Si retomas el proyecto en frío, lee `ARRANQUE.md` y `PENDIENTES.md`. Con esos
dos tienes todo.** El resto es detalle que se consulta cuando toca.

Todo esto vive en dos sitios a la vez: en `~/cerebro-fase1/` (máquina de
Humberto) y en `docs/negocio/` del repo `hmartinezenzona-rgb/wacrm`. **El repo
es el que manda**, porque sobrevive a la máquina y a las sesiones.

---

## Por dónde empezar

| Documento | Cuándo leerlo |
|---|---|
| **`ARRANQUE.md`** | **Siempre, lo primero.** Accesos, IDs, cómo se despliega, cómo se prueba, cómo se trabaja |
| **`PENDIENTES.md`** | Justo después. Abre con un cuadro de una pantalla con todo lo que falta |

## Antes de tocar según qué

| Documento | Léelo antes de… |
|---|---|
| `12-el-modelo-no-debe-pensar.md` | **tocar el modelo del agente** |
| `11-lenguaje-deliberativo-rompe-deepseek.md` | **tocar el prompt** |
| `PLAN-2E-outbox.md` | **tocar el outbox** (fases 2 y 3) |
| `14-lo-que-se-le-dice-al-cliente-sale-del-sql.md` | **tocar el `Decisor`** o lo que el bot confirma al cliente |
| `15-la-via-de-deposito-por-defecto.md` | tocar las cuentas de depósito o la vía |
| `16-fugas-de-razonamiento-y-bucles.md` | tocar `Normalizar formato` o `Control de abuso` |
| `17-no-prometer-la-transferencia-sin-beneficiario.md` | tocar el **notificador por etapa** o lo que se promete al cliente |
| `18-dos-caidas-silenciosas.md` | **tocar cualquier consulta de un workflow**, y para entender qué NO vigila el sistema |
| `19-que-se-le-pide-al-cliente.md` | **tocar el `Decisor`** o lo que el bot pide y promete |
| `10-vision-doble-lectura.md` | tocar la lectura de comprobantes (cuatro giros) |
| `13-normalizador-de-formato.md` | tocar el formato de las respuestas |

## Cómo funciona el negocio

| Documento | Qué tiene |
|---|---|
| `RESPUESTAS-OSMANY-servicios.md` | **Precios, costes y reglas en palabras de Osmany.** Lo más caro de conseguir |
| `SERVICIOS-tramo1.md` | Diseño de los servicios que no son remesas |
| `PEDIR-A-OSMANY-contabilidad.md` | La pregunta que falta para calcular ganancias |

## Planificación

| Documento | Qué tiene |
|---|---|
| `FASES-ANALISIS-COMPLETO.md` | Balance de las 3 fases del spec contra lo que hay. **Por qué no se sigue al pie de la letra** |
| `FASE2-ANALISIS.md` | Análisis a fondo de la Fase 2: dependencias y riesgos |
| `PENDIENTE-bot-callado-en-chats-ocultos.md` | Registro de una especificación que se implementó tal cual |

---

## Las migraciones

En `supabase/migrations/` del mismo repo. **Todas llevan dentro cómo se
probaron y cómo se revierten**, y están marcadas «ya aplicada, no la ejecutes».

| | Qué |
|---|---|
| `001`–`039` | Fase 1, cruce de depósitos, avisos de incidencia, vigilante de rechazos |
| `040`–`044` | **Fase 2**: operaciones, escritura dual, beneficiarios, log de tools |
| `045` | Purga semanal de logs (`pg_cron`) |
| `046` | Pipeline de Servicios y `service_type` |
| `047`–`050` | Promociones de Etecsa: detección, confirmación y aviso previo |
| `051` | Outbox — **solo la fase 1 (sombra) está aplicada** |
| `052` | Las remesas entregadas se cierran solas |
| `053` | Vistas de volumen e historial |
| `054` | Visa: pasos posteriores y regla de rebajas |
| `055` | RPC del dashboard (`/resumen` del CRM) |
| `056` | La asignación manual de un chat caduca sola a los 10 min |
| `057` | Vigilante de chats asignados sin respuesta |
| `058` | **PENDIENTE** — borrar un deal debe cancelar su operación |

## Las copias de seguridad

`ROLLBACK-*.json` en `~/cerebro-fase1/`. **Una por cada cambio del workflow**, y
son la vía de vuelta real: restaurar el fichero con un `PUT` y reactivar.

---

## Lo que NO está aquí

- **Las credenciales.** Viven en ficheros del disco (`~/.n8n-api-key`,
  `~/.github-token`, `~/.telegram-token`, `~/.cerebro-secret`). Nunca en el repo,
  nunca en el chat.
- **El código de WaCRM.** Es de Hermes; está en el mismo repo pero en `src/`.
- **Lo anterior al 3-ago-2026.** El CRM no existía; vive en la hoja de Osmany.
