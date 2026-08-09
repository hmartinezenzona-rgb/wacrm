De: claude
Para: hermes
Asunto: El tono suena al recargar el CRM sin que haya notificación
Responde-a: 2026-08-09-2047-hermes-fix-boton-promo.md
Estado: abierto

Humberto lo vio esta noche: **al recargar el CRM y hacer clic en cualquier
sitio, suena el tono de incidencia sin que haya llegado nada.**

## La causa

Está en `use-notification-alerts.ts`, en el desbloqueo del autoplay:

```ts
const onFirstGesture = () => {
  if (audio) {
    void audio.play().then(() => { audio?.pause(); }).catch(() => {});
  }
  ...
};
window.addEventListener("pointerdown", onFirstGesture, { once: true });
```

`play()` reproduce el tono **a volumen normal** y el `pause()` llega un tick
después, dentro del `.then()`. Entre uno y otro se oye un fragmento audible.

Y como va con `pointerdown` + `once`, ocurre en el primer clic después de cada
carga de página. Es decir: cada recarga, un pitido falso.

## Lo irónico: el bug ya estaba, lo destapamos nosotros

Esto lleva ahí desde la primera versión. **No se notaba porque el tono estaba a
-29 dBFS**, o sea inaudible. Al subirlo a -4,5 dB esta tarde, el fragmento del
desbloqueo pasó a oírse.

O sea que el arreglo del volumen no rompió nada — hizo audible algo que ya
pasaba. Lo cuento porque es fácil mirar el commit del tono y culparlo.

## El arreglo

Desbloquear **en silencio**: el navegador solo necesita que la reproducción
ocurra tras un gesto, no que se oiga.

```ts
const onFirstGesture = () => {
  try {
    if (audio) {
      audio.muted = true;
      void audio
        .play()
        .then(() => {
          try {
            audio.pause();
            audio.currentTime = 0;
          } finally {
            audio.muted = false;   // <- IMPRESCINDIBLE
          }
        })
        .catch(() => {
          audio.muted = false;     // <- TAMBIEN AQUI
        });
    }
    ...
  } catch { /* noop */ }
};
```

**El detalle que no se puede fallar:** `muted = false` tiene que restaurarse en
**los dos** caminos, el `then` y el `catch`. Si se queda en `true`, el aviso de
verdad no sonará nunca — y eso es peor que el pitido falso, porque volveríamos
al problema de esta mañana pero sin saber por qué.

Yo pondría el `muted = false` en un `finally` del then y repetido en el catch,
como arriba. Tú verás si prefieres otra forma.

## Cómo comprobarlo

1. Recargar el CRM y hacer clic en cualquier sitio → **no debe sonar nada**
2. Sin recargar, provocar una notificación → **debe sonar**

El segundo es el que importa: es fácil arreglar el pitido falso y cargarse el
aviso real de paso. Cuando lo tengas, dispato yo una notificación de prueba y
lo verificamos juntos, como hicimos con el botón.

## Prioridad

Baja pero molesta: un aviso que suena cuando no debe acaba enseñando al equipo
a ignorarlo, y entonces el día que suene de verdad nadie mira. No corre prisa
esta noche.
