# Plan — Tercer vigilante: mensajes de clientes que se pierden

> **Estado al cierre del 10-ago: MONTADO Y ACTIVO, a la espera de que WaCRM
> escriba en la tabla.** La migración `061` creó `whatsapp_webhook_log` y la
> función `cerebro_avisar_mensajes_perdidos()`, y el workflow
> **`HVNAIc8otXHejsw4`** corre cada 10 minutos. Falta **solo** que Hermes añada
> las dos escrituras en `route.ts` (buzón `2026-08-10-1810-claude-tabla-lista.md`).
> Mientras tanto la tabla está vacía: **no molesta, pero tampoco protege**.
>
> El reparto cambió sobre lo escrito abajo: la tabla la hice yo, porque la base
> de datos es mi lado. A Hermes le queda el código, y nada más.

Escrito el **10 de agosto de 2026**, después del incidente del cliente
`592 6731279`: escribió cinco veces con doble tick y **ninguno de sus mensajes
llegó al CRM**. Nos enteramos porque buscó a Osmany por su cuenta.

---

## Por qué este y no el que parecía obvio

Lo primero que se pensó fue vigilar **el dinero**: «entró un depósito y nadie lo
ha reclamado en N horas». **Se descartó midiendo**, y conviene dejar escrito por
qué para que nadie lo reproponga.

**Razón 1 — la cola es larga y legítima.** Cuánto tarda un cliente en mandar el
comprobante después de que el correo de MMG llega, sobre 36 cruces reales (fuera
la carga histórica del 5-ago):

| Tarda | Casos |
|---|---|
| Menos de 30 min | 18 |
| 30 min – 2 h | 8 |
| 2 – 8 h | 3 |
| 8 – 24 h | 3 |
| **Más de 24 h** | **4** |
| Peor caso legítimo | **47,5 h** |

Con umbral de 8 h habrían saltado **10 falsas alarmas en 6 días**.

**Razón 2, la que lo mata — el correo de MMG no dice quién depositó.**

```
Hi Osmany, You have deposited $ 5,000 to your wallet. TransID 20397553791857
```

Ni nombre ni número. **No hay forma de distinguir el depósito de un cliente de un
movimiento del propio Osmany.** En 6 días entraron **68 depósitos y solo 25 se
cruzaron**: los otros 43 son en su mayoría dinero suyo, y cada uno dispararía una
alarma **que nunca se podría cerrar**, porque nadie va a venir a reclamarla.

Serían ~7 alarmas diarias imposibles de cerrar. Eso no es un vigilante: es
entrenar al equipo a ignorar la campana. Es el mismo motivo por el que se
descartó el vigilante por volumen de depósitos (ver `21-vigilante-de-la-ingesta.md`).

> **La regla que sale de aquí:** vigilar **la causa concreta**, no una
> correlación con el dinero. El agujero no es «entró dinero y nadie lo reclama»,
> es **«un cliente escribió y no nos enteramos»**. Hay que vigilar exactamente eso.

---

## Lo que hace falta de Hermes

Este vigilante **no puede existir sin la tabla**. Hoy WaCRM no guarda nada de lo
que Meta le entrega, así que un mensaje perdido no deja ni la huella de haber
existido.

Contrato mínimo de `whatsapp_webhook_log`:

| Columna | Tipo | Para qué |
|---|---|---|
| `id` | uuid PK | |
| `recibido_en` | timestamptz, default now() | cuándo entró el webhook |
| `phone_number_id` | text | qué número del negocio |
| `wamid` | text | id del mensaje en Meta |
| `remitente` | text | **el número del cliente — esto es lo que se vigila** |
| `tipo` | text | `text`, `image`, `audio`… |
| `procesado` | boolean, default false | **se pone `true` al terminar bien** |
| `error` | text null | el mensaje de la excepción, si la hubo |
| `payload` | jsonb | por si hay que reprocesar |

**Dos cosas que no son negociables:**

1. La fila se escribe **antes** de procesar, no después. Si se escribe al final,
   un fallo a mitad no deja fila y volvemos al punto de partida.
2. `procesado` pasa a `true` **solo cuando el mensaje está guardado** en
   `messages`. Ni antes.

Índice necesario: `(procesado, recibido_en)` — el vigilante consulta cada 10
minutos y esa consulta tiene que ser barata.

Retención: 7–14 días. Un borrado diario de lo procesado y viejo basta.

> **Cuidado:** el `payload` lleva mensajes de clientes. Que no salga de la base
> ni acabe en un log en claro.

---

## El vigilante

Mismo molde que los otros dos (`NiibUBRtOlOppmY4` y `bTwsEJsmoAzsuOxm`):
workflow de n8n, **cada 10 minutos**, un solo nodo Postgres que consulta y avisa
en la misma sentencia, aviso en el CRM.

```
Cada 10 minutos → Avisar mensajes perdidos
```

### La consulta

```sql
-- MENSAJE DE UN CLIENTE QUE NO LLEGO AL CRM.
-- Una fila en whatsapp_webhook_log con procesado=false pasados N minutos
-- significa: WaCRM recibio el mensaje de Meta y NO lo guardo. El cliente cree
-- que nos escribio y nadie lo ha visto.
-- A diferencia del vigilante de depositos, aqui NO hay falsos positivos: o el
-- mensaje se guardo o no se guardo.
WITH abierto AS (
  SELECT (EXTRACT(dow  FROM now() AT TIME ZONE 'America/Guyana') BETWEEN 1 AND 6
      AND EXTRACT(hour FROM now() AT TIME ZONE 'America/Guyana') BETWEEN 9 AND 16) AS si
),
candidatos AS (
  SELECT w.remitente,
         count(*)                                   AS cuantos,
         min(w.recibido_en)                         AS primero,
         round(EXTRACT(epoch FROM (now()-min(w.recibido_en)))/60) AS minutos,
         coalesce(max(w.error), 'sin detalle')      AS motivo
    FROM whatsapp_webhook_log w
   WHERE w.procesado = false
     AND w.recibido_en < now() - (COALESCE(cerebro_config_get('perdido_minutos'),'10')::int * interval '1 minute')
     AND w.recibido_en > now() - interval '24 hours'
   GROUP BY w.remitente
),
nuevos AS (
  SELECT c.* FROM candidatos c
   WHERE NOT EXISTS (
     SELECT 1 FROM notifications n
      WHERE n.type = 'mensaje_perdido'
        AND n.body LIKE '%' || c.remitente || '%'
        AND n.created_at > now() - (COALESCE(cerebro_config_get('perdido_repetir_min'),'120')::int * interval '1 minute'))
)
INSERT INTO notifications (account_id, user_id, type, title, body)
SELECT '465fb4ce-33b6-4473-ad2c-42818772f587', u, 'mensaje_perdido',
       'Mensaje de ' || n.remitente || ' NO llego al CRM (' || n.cuantos || ')',
       'El cliente ' || n.remitente || ' escribio hace ' || n.minutos ||
       ' min y su mensaje NO se guardo. El ve doble tick de entregado.' ||
       chr(10) || chr(10) ||
       'Mensajes afectados: ' || n.cuantos || '. Motivo: ' || n.motivo ||
       chr(10) || chr(10) ||
       'Hay que escribirle a mano. No espera respuesta del bot porque el bot ' ||
       'nunca vio el mensaje.'
  FROM nuevos n
  CROSS JOIN unnest(ARRAY['e3c7943d-b2fa-4c53-ae2f-406f1533ed47',
                          '5c4d16fd-1530-4023-8119-b58e04cc815f',
                          'ca797265-a1b3-43f7-9d9f-68c15d1f4780']::uuid[]) AS u
 WHERE (SELECT si FROM abierto)
RETURNING id::text;
```

### Las decisiones, y por qué

**Se agrupa por remitente.** El cliente del incidente perdió cinco mensajes; con
una fila por mensaje serían cinco avisos del mismo problema. Uno por cliente, con
la cuenta dentro.

**El umbral es de 10 minutos, no de horas.** Aquí no hay cola larga que respetar:
o WaCRM guardó el mensaje o no lo guardó. Los 10 minutos solo dan margen a un
reintento o a un proceso lento, no a la conducta del cliente.

**Se mira solo las últimas 24 h.** Un mensaje perdido hace tres días ya no se
arregla avisando; lo que hace es tener la campana sonando para siempre.

**Solo en horario de atención**, como la `057` y la `059`. Un aviso a las 23:00
no lo lee nadie.

**El texto dice qué hacer**: escribirle a mano, y que no espere respuesta del bot
—el bot nunca vio el mensaje—. Un aviso que no dice la acción no sirve.

---

## Migración `061`

`060` está reservada para la rama DELETE de `trg_sync_operacion_desde_deal`.

```sql
ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type = ANY (ARRAY['conversation_assigned'::text,
                           'deal_incidencia'::text,
                           'mensaje_fallido'::text,
                           'promo_etecsa'::text,
                           'chat_atascado'::text,
                           'ingesta_caida'::text,
                           'deposito_sin_cruzar'::text,
                           'mensaje_perdido'::text]));

INSERT INTO cerebro_config (clave, valor) VALUES
  ('perdido_minutos','10'),
  ('perdido_repetir_min','120')
ON CONFLICT (clave) DO NOTHING;
```

> **Esta migración va ANTES de activar el workflow.** El 10-ago el vigilante de
> la ingesta se desplegó detectando bien y **sin poder avisar**, porque el tipo
> `ingesta_caida` no estaba en la restricción. Se descubrió solo porque se probó
> el fallo a propósito. Ver `058_tipo_aviso_ingesta_caida.sql`.

---

## Cómo se prueba, antes de darlo por bueno

Las dos caras, contra el sistema real, con las filas dentro de un bloque que se
revierte (`DO $ … RAISE EXCEPTION … $`):

| Prueba | Qué tiene que pasar |
|---|---|
| Sin filas sin procesar | **0 avisos** |
| Una fila `procesado=false` de hace 20 min | **3 avisos**, uno por admin, con el número dentro |
| Tres filas del mismo remitente | **3 avisos** (uno por admin), no nueve — la agrupación funciona |
| Repetir la pasada enseguida | **no repite** — el throttle funciona |
| Fila de hace 30 h | **0 avisos** — la ventana de 24 h funciona |

**Y la que de verdad importa:** provocar el fallo de verdad. Con el arreglo de
Hermes desplegado, mandar al número de pruebas un mensaje cuyo remitente no
traiga perfil ya no debería perderse; lo que hay que comprobar es que **si algún
día se pierde otra cosa**, la fila queda con `procesado=false` y el aviso sale.

---

## Lo que sigue sin cubrir

- **Que Meta no entregue el webhook.** Si la petición nunca llega al VPS, no hay
  fila que vigilar. Eso solo se ve en el panel de entregas de Meta. Sigue siendo
  un punto ciego y conviene saberlo.
- **Reprocesar automáticamente.** Con el `payload` guardado se podría reintentar
  en vez de solo avisar. Es el paso natural siguiente, pero es código de WaCRM y
  va aparte: primero que avise bien.

---

## Reversión

Desactivar el workflow. No escribe nada salvo avisos y nada depende de él. La
migración puede quedarse: un tipo de aviso de más no molesta.
