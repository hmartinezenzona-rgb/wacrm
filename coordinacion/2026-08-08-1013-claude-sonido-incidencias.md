De: claude
Para: hermes
Asunto: Sonido y aviso de escritorio cuando un envío cae en Incidencia
Estado: abierto

La mitad de base de datos ya está hecha y aplicada en producción. Lo que
queda es solo frontend, y es corto porque casi toda la fontanería existía.

Va también `supabase/migrations/038_notificacion_deal_incidencia.sql` en
este mismo commit. **Ya está aplicada, no la ejecutes** — está ahí para que
el repo refleje la realidad, igual que la 037.


**Qué se busca:** que cuando un envío caiga en **Incidencia**, además del mensaje
de WhatsApp que ya sale, **suene un aviso en el CRM** y salte una notificación
del escritorio, aunque la pestaña esté en segundo plano.

**La mitad ya está hecha y no hay que tocarla.** Existe la tabla
`notifications`, su realtime, su RLS por usuario, la página y el badge de la
barra lateral. Y el hook `useUnreadNotifications` vive en `sidebar.tsx`, que está
en el layout del panel, así que ya se ejecuta en todas las páginas.

**La parte de base de datos ya está aplicada en producción** (yo). Lo que queda
es solo frontend.

---

## 0. Lo que ya hice — para que lo tengas en cuenta

Migración `038_notificacion_deal_incidencia.sql`, **ya aplicada**. Te la paso
para que la commitees al repo junto a la `037`, no hace falta que la ejecutes.

Hace dos cosas:

1. Amplía el `CHECK` de `notifications.type` para admitir **`deal_incidencia`**.
2. Añade un disparador en `deals` que, al entrar en Incidencia, crea **una fila
   por cada usuario de la cuenta** (aquí son tres: Admin, eliaba, osmany).

Probado: crea los 3 avisos, con título `Incidencia: Remesa +5926132064 - 5,000
GYD` y como cuerpo la última línea de las notas del deal, que es el motivo.

> **Aviso por si tocas algo de `profiles`:** esa tabla tiene **dos** columnas de
> identidad, `id` y `user_id`. La que vale para `notifications.user_id` es
> **`user_id`**, porque la clave ajena apunta a `auth.users`. Yo usé `id` en el
> primer intento y el disparador falló **en silencio**, porque se traga los
> errores a propósito para no tumbar la actualización del deal. Me costó un rato
> encontrarlo; te lo digo para que no te pase.

---

## 1. El tipo nuevo en TypeScript

`src/types/index.ts` — donde está `NotificationType`, añade el valor:

```ts
'conversation_assigned' | 'deal_incidencia'
```

`src/app/(dashboard)/notifications/page.tsx` — en `TYPE_ICON` añade la entrada.
El propio comentario del fichero dice que los tipos futuros son *"una línea"*:

```ts
const TYPE_ICON: Record<Notification["type"], typeof Bell> = {
  conversation_assigned: Bell,
  deal_incidencia: AlertTriangle,   // de lucide-react
};
```

Hay un `?? Bell` de reserva, así que aunque se olvide no rompe nada.

---

## 2. El fichero de sonido

No hay ninguno. En `public/` solo está `opus/encoderWorker.min.js`, que es el
codificador de las notas de voz.

Añade uno corto, **de menos de un segundo**, en `public/sounds/incidencia.mp3`.
Que sea discreto: esto va a sonar en una oficina y un pitido agresivo acaba
desactivado por quien lo sufre.

---

## 3. El hook

Nuevo fichero `src/hooks/use-notification-alerts.ts`. **No metas esto dentro de
`use-unread-notifications.ts`**: ese hook devuelve un número y conviene que siga
haciendo solo eso.

Lo que tiene que hacer:

- Suscribirse a los `INSERT` de `notifications`. **No hace falta filtrar por
  usuario**: la RLS ya lo hace, igual que en el hook del contador.
- Usar un nombre de canal distinto del que ya existe. El otro se llama
  `notifications-unread-count`; usa por ejemplo `notifications-alerts`.
- Al llegar un `INSERT`, reproducir el sonido y lanzar la notificación de
  escritorio con `title` y `body` de la fila.
- Al pulsar la notificación, llevar a la conversación si trae
  `conversation_id`, y si no a `/notifications`.

Móntalo **una sola vez**, en `src/app/(dashboard)/dashboard-shell.tsx`. Si lo
pones en un componente que se repite, sonará varias veces por aviso.

### Los dos detalles que se suelen escapar

**El navegador bloquea el audio hasta que alguien toca la página.** Es una
protección contra los anuncios. Si el operador ya lleva un rato haciendo clic no
se nota, pero una pestaña recién abierta y sin tocar se traga el primer aviso.
Se resuelve desbloqueando el audio en la primera interacción: un listener
`once: true` sobre `pointerdown` que haga `play()` y `pause()` del audio para
dejarlo autorizado.

**El permiso de notificaciones hay que pedirlo desde un gesto del usuario**, no
al montar el componente. Chrome ignora la petición si viene sola al cargar. Lo
más limpio es un interruptor en ajustes, o pedirlo en el primer clic junto con
el desbloqueo del audio.

Y una regla: **si `Notification.permission` está en `denied`, no insistas**. Que
el sonido siga funcionando por su cuenta.

---

## 4. Cómo probarlo

Con el CRM abierto, mueve a mano un deal a **Incidencia** desde el tablero.
Deben pasar cuatro cosas: suena, salta el aviso del escritorio, sube el badge
de la barra lateral y aparece en `/notifications`.

Prueba también:

| | Qué | Qué debe pasar |
|---|---|---|
| 1 | Con la pestaña **en segundo plano** | Suena igual y salta el aviso del escritorio |
| 2 | Pestaña recién abierta, **sin tocar nada** | No debe petar. Si no suena, es el bloqueo del navegador |
| 3 | Con el permiso **denegado** | Suena igual, sin errores en consola |
| 4 | Dos incidencias seguidas | Dos avisos, no uno |
| 5 | **Asignar una conversación** | Que el aviso de siempre siga funcionando |

La 5 es la que importa: lo nuevo no vale nada si rompe lo que ya iba.

---

## 5. Lo que NO hay que tocar

- **Nada del flujo de dinero.** Ni `deals`, ni el cruce de depósitos, ni los
  disparadores que ya existen. El aviso es un añadido y tiene que poder quitarse
  sin que se entere nadie más.
- **El mensaje de WhatsApp al admin se queda.** Es lo único que avisa cuando no
  hay nadie con el CRM abierto.
- `use-unread-notifications.ts` y su canal.

---

## 6. Lo que queda fuera a propósito

Con el navegador **cerrado** no va a sonar nada. Para eso haría falta Web Push
con service worker y claves VAPID, que es bastante más trabajo. Se habló y se
decidió dejarlo para más adelante.
