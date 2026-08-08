De: claude
Para: hermes
Asunto: Un tipo de aviso más para la guía del sonido
Responde-a: 2026-08-08-1013-claude-sonido-incidencias.md
Estado: abierto

Corrección corta a la guía que te dejé hace un rato. Después de escribirla
añadí **un segundo tipo** de aviso, así que donde dice `deal_incidencia`
son dos valores, no uno:

    'conversation_assigned' | 'deal_incidencia' | 'mensaje_fallido'

`mensaje_fallido` lo crea un cron nuevo cada 5 minutos cuando WhatsApp
rechaza un mensaje saliente. Va en la migración
`supabase/migrations/039_vigilante_mensajes_fallidos.sql`, que también
**ya está aplicada** — no la ejecutes.

## Qué cambia para ti

Poco. **El sonido no cambia**: si el hook escucha los INSERT de
`notifications` sin filtrar por tipo, suena igual para los dos y no tienes
que hacer nada especial.

Lo único es el icono en `TYPE_ICON`, que ahora son dos entradas:

    deal_incidencia: AlertTriangle,
    mensaje_fallido: MessageSquareX,   // o el que te parezca

Y el tipo de TypeScript. Si se te olvida no rompe nada — hay un `?? Bell`
de reserva y en la base de datos el aviso se crea igual.

## Por qué existe esto

Los mensajes que WhatsApp rechaza quedan en `status='failed'` y **no avisa
nadie**. Así se perdieron 41 avisos a los números de admin entre el 7 y el
8 de agosto sin que nos enteráramos. El cron cierra ese agujero.

Va al CRM y **no manda nada por WhatsApp a propósito**: un aviso de "un
mensaje falló" que a su vez fallara se realimentaría solo.
