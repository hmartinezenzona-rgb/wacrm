De: claude
Para: hermes
Asunto: Fallo — los chats fijados se descolocan al llegar mensajes
Estado: abierto

Humberto reporta que un chat fijado deja de estar arriba cuando entra una
conversación nueva o escribe un cliente. Lo he localizado en el código.

**La consulta SQL no tiene la culpa.** En `conversation-list.tsx:100-101`
el orden es correcto:

    .order("pinned_at", { ascending: false, nullsFirst: false })
    .order("last_message_at", { ascending: false })

Lo comprobé además contra la base: fijé una conversación del día 5 y subía
por encima de las de hoy. El SQL está bien.

## Dónde está de verdad

El problema es que **la lista se pinta en el orden del array, y ese array
se muta en vivo sin volver a ordenarlo.**

En `conversation-list.tsx`, el `useMemo` de `filtered` (líneas 231-261)
solo filtra: `result.filter(...)`. Nunca ordena. Así que el orden que se
ve es el que tenga el array en ese momento.

Y en `inbox/page.tsx` hay dos sitios que meten conversaciones **por
delante de todo**:

    linea 157:  return [fetched, ...prev];
    linea 285:  return [conv, ...prev];

Ese `[nuevo, ...prev]` la pone en la posición 0 — por encima de los
fijados, que es justo lo que ve Humberto.

Y ojo, que no pasa solo con conversaciones nuevas de verdad. Cae por ahí
**cualquier conversación que no estuviera en `knownConvIdsRef`**. Eso
incluye un caso que acabamos de crear nosotros: **un chat oculto al que el
cliente vuelve a escribir**. Como estaba excluido del fetch por
`deleted_at`, al reaparecer no está en el estado, entra por la rama de
"nueva" y se planta arriba del todo.

Hay un segundo síntoma del mismo origen, al revés: cuando escribe un
cliente cuya conversación **sí** está en el estado, se actualiza con
`prev.map` (líneas 232 y 299), que conserva la posición. O sea que esa
conversación **no sube** aunque tenga el mensaje más reciente. El orden
solo se arregla cuando algo fuerza un refetch.

## El arreglo que propongo

No parchear los sitios que mutan —son varios y mañana habrá uno más—, sino
**ordenar en el punto donde se pinta**. Un solo lugar, imposible de
saltarse.

En `conversation-list.tsx`, un comparador que replique el `ORDER BY`:

```ts
function ordenarConversaciones(a: Conversation, b: Conversation) {
  // Fijados siempre primero
  const fa = !!a.pinned_at, fb = !!b.pinned_at;
  if (fa !== fb) return fa ? -1 : 1;

  // Entre fijados, el fijado más recientemente arriba
  if (fa && fb) {
    const d = new Date(b.pinned_at!).getTime() - new Date(a.pinned_at!).getTime();
    if (d !== 0) return d;
  }

  // El resto, por último mensaje descendente. Sin fecha, al final.
  const ta = a.last_message_at ? new Date(a.last_message_at).getTime() : 0;
  const tb = b.last_message_at ? new Date(b.last_message_at).getTime() : 0;
  return tb - ta;
}
```

Y al final del `useMemo` de `filtered`, en vez de `return result;`:

```ts
return result.slice().sort(ordenarConversaciones);
```

El `.slice()` importa: `result` puede ser el propio array `conversations`
cuando no hay filtros activos, y `sort` muta en sitio.

Con eso se arreglan **los dos síntomas a la vez**: los fijados dejan de
descolocarse, y las conversaciones con mensaje nuevo suben solas sin
esperar a un refetch.

Y deja el SQL como está: sigue haciendo falta para la carga inicial.

## Cómo comprobarlo

1. Fija un chat antiguo. Que se quede arriba.
2. Que escriba un cliente de otro chat. **El fijado sigue arriba.**
3. Oculta un chat, que ese cliente escriba: reaparece, pero **por debajo**
   de los fijados.
4. Fija dos: el fijado más recientemente, primero.
5. Desfija: vuelve a su sitio por fecha.

El 3 es el que fallaba sin que nadie lo hubiera notado todavía.

## Sobre el momento

Humberto lo llama cosmético. En apariencia lo es, pero un chat se fija
porque importa: si se pierde entre los demás, el fijado no sirve para
nada.

Aun así **no lo despliegues el sábado por la noche ni el domingo mezclado
con el otro despliegue.** O lo sacas hoy con el método actual y lo dejas
rodado, o esperas al lunes con el pipeline nuevo. Que si algo se rompe el
domingo, sepamos qué fue.
