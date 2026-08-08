De: claude
Para: hermes
Asunto: El bot le pisa la conversación a un humano — con caso real
Estado: abierto

Analizando una conversación real (592 608 2754, Yoandris) salió esto. No
es teoría: pasó el 6 de agosto y costó un cliente.

## Lo que ocurrió

    07:57  HUMANO:   "Aun no tengo configurado lo del los combos"
    07:57  HUMANO:   "Si hago"                  <- le dice que SI los hace
    07:57  HUMANO:   "Para donde lo quieres?"
    08:15  Cliente:  "Para las tuna"
    08:16  BOT:      "Perfecto, ¿cuánto desea enviar?"     <- interrumpe
    08:17  Cliente:  "Combo de comida"
    08:17  BOT:      "no manejamos combos de comida"       <- CONTRADICE al humano
    08:17  Cliente:  "Ok"
    08:54  HUMANO:   "Lo siento, aun el box no está adiestrado"

Humberto le dijo que sí ofrecía el servicio y veinte minutos después el
bot le dijo que no. El cliente contestó "Ok" y se acabó la venta.

## La causa

El Cerebro solo se calla si la conversación tiene `assigned_agent_id`.
Responder a mano desde la interfaz **no la asigna**, así que el bot sigue
trabajando en paralelo sin enterarse de que hay una persona atendiendo.

Es el mismo patrón que el chat oculto: hacer algo "de humano" no silencia
al robot.

## El arreglo — es tuyo, y el Cerebro no se toca

**Que WaCRM asigne la conversación automáticamente cuando un humano
escribe desde la interfaz.** Algo equivalente a:

    assigned_agent_id = COALESCE(assigned_agent_id, <el usuario que escribe>)

El `COALESCE` importa: si ya está asignada a otro compañero, no se la
quites.

Con eso el `ctx.asignado` que el Decisor ya comprueba hace el resto. **No
hay que cambiar nada en n8n.**

Ojo: solo debe dispararlo un mensaje escrito por una **persona** desde la
interfaz. Los que envía el bot por `/api/v1/messages` no, obviamente — si
no, se autoasignaría a sí mismo y se callaría para siempre.

## PENDIENTE DE HUMBERTO antes de que lo implementes

Este cambio tiene una consecuencia: **a partir de ahí, cualquier chat donde
alguien conteste a mano queda asignado y el bot deja de atenderlo** hasta
que se libere con el comando `liberar <numero>`.

Eso es lo que ya significa "asignado" hoy, y encaja con la intención —si
contestas, es porque lo llevas tú—. Pero si Humberto responde una duda
suelta y se olvida de liberar, ese cliente se queda sin bot para siempre.

La alternativa sería una **ventana de silencio**: el bot calla N minutos
tras un mensaje humano y luego retoma solo. Se cura sola, pero es lógica
del Cerebro y necesita antes lo de abajo.

**No lo implementes hasta que Humberto elija.** Yo se lo pregunto.

## Y algo independiente que sí puedes ir haciendo

En `messages` **no hay forma de distinguir un mensaje del bot de uno de
una persona**: los dos tienen `sender_id` nulo y `ai_generated` en
`false`. Los separé por el estilo de escritura, no por los datos.

Eso significa que no puedo medir cuántas veces ha pasado esto, y que en el
CRM tampoco se ve quién dijo qué.

¿Puedes hacer que los mensajes que entran por `/api/v1/messages` queden
marcados como generados por IA, o que los de la interfaz lleven el
`sender_id` del usuario? Con cualquiera de las dos me vale.

Es barato y desbloquea tanto la medición como la ventana de silencio, si
al final vamos por ahí.
