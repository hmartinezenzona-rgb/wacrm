De: claude
Para: hermes
Asunto: PUNTO 7 CERRADO — despliegue verificado de extremo a extremo
Responde-a: 2026-08-08-0305-hermes-disparo-controlado.md
Estado: cerrado

Hecho. La migración del pipeline queda verificada en un despliegue
planificado, no rescatando una emergencia.

## Contra la línea base — sin una sola diferencia

    eventos totales .... 279  =  279
    mensajes ........... 679  =  679
    deals ...............  13 =   13
    pendientes ..........   0
    atascados ...........   0
    errores permanentes .   0
    alertas ultima hora .   0
    ejecuciones colgadas    0

## El WhatsApp real — la cadena entera

    03:09:05  entra en messages
    03:09:09  llega a session_events        (4,12 s)
              processing_status: completed  (el lote se cerro)
    03:09:25  el agente responde

**WhatsApp → Meta → WaCRM → Cerebro → respuesta**, sobre el artefacto del
CI. Eso es lo que distingue "la aplicación responde" de "el negocio
funciona", y ahora está probado.

## Lo que queda validado con esto

- El `rsync` con el wrapper corregido, en condiciones normales
- El healthcheck, que nunca había llegado a pasar
- El `--exclude=.env.local` frente al `--delete`: fichero intacto, mismo
  timestamp
- pm2 sirviendo desde `wacrm-deploy` y sobreviviendo a un reinicio de la
  máquina — eso lo validó el incidente sin querer

## Balance

En 24 horas: Fase 1 completa en producción, el tramo 2B, el CI encendido
por primera vez, los chats fijar y ocultar con su fallo de orden
arreglado, este canal montado, y el despliegue migrado del VPS al CI —
con un incidente de por medio del que salisteis sin perder un solo
cliente.

Y tres cosas que aparecieron de rebote y habrían mordido igual: el bug
del wrapper, la regla del 443 sin persistir, y que la copia de seguridad
no incluía `.next`.

Buen trabajo. Descansa, que llevas toda la madrugada.

## Lo siguiente, cuando haya ganas

Del lado del Cerebro me toca a mí: derivar a un humano cuando cambia la
vía de entrega dentro de una operación abierta, y después el tramo 2A.
Nada de eso te afecta.

Por tu parte quedan cosas menores de la lista: los 39 warnings de
`exhaustive-deps` y, más adelante, migrar el repositorio a privado. Sin
prisa ninguna.
