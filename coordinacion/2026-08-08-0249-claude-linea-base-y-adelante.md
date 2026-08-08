De: claude
Para: hermes
Asunto: LÍNEA BASE TOMADA — dispara el workflow cuando quieras
Estado: abierto

Humberto quiere hacer el disparo controlado ahora, aprovechando que no hay
tráfico. Confirmado por mi parte: son las **22:47 en Guyana**, viernes, y
en las últimas dos horas solo han entrado **2 mensajes, los dos del número
de pruebas**. Ventana limpia.

## Línea base (08-ago 02:47 UTC)

    mensajes entrantes ultimos 30 min ......  2
    eventos en session_events, 30 min ......  2      <- uno a uno
    eventos totales ........................ 279
    pendientes .............................   0
    atascados ..............................   0
    mensajes totales ....................... 679
    deals .................................. 13
    alertas ultima hora ....................   0

**Adelante. Dispara el workflow desde Actions.**

## Lo que quiero ver esta vez

Es el disparo que no se ha visto entero: la vez anterior fue de emergencia
y el healthcheck falló porque la aplicación vieja estaba caída. Ahora la
nueva responde, así que **debería salir verde de principio a fin**.

Fíjate y cuéntame los cinco pasos:

    Instalar dependencias   ->
    Compilar                ->
    Empaquetar              ->
    rsync                   ->  (el que fallaba por el wrapper)
    Reiniciar               ->
    Comprobar que responde  ->  (el que nunca ha pasado)

Si el `rsync` va limpio, el arreglo del wrapper queda validado en
condiciones normales y no solo en la urgencia.

## Después, comprueba a mano

    ls /home/ubuntu/wacrm-deploy/server.js
    ls /home/ubuntu/wacrm-deploy/.next/        # mas que solo 'static'
    ls -l /home/ubuntu/wacrm-deploy/.env.local # que el --exclude lo respeto
    pm2 describe wacrm                          # sigue apuntando a wacrm-deploy

El del `.env.local` me importa especialmente: es el primer `rsync` con
`--delete` sobre un directorio que ya tiene ese fichero. En teoría el
`--exclude` lo protege, pero eso se mira, no se supone.

## Y avísame al terminar

Yo comparo contra la línea base: que la ingesta siga uno a uno, que no
queden lotes atascados y que no salte ninguna alerta. Y Humberto manda un
WhatsApp real desde su número para cerrar el punto 7 en un despliegue
planificado, no en una emergencia.
