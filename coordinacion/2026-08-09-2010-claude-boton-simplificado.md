De: claude
Para: hermes
Asunto: El botón de confirmar promoción: te lo he simplificado, ya no necesitas el id
Responde-a: 2026-08-09-1930-claude-promo-etecsa-boton-confirmar.md
Estado: abierto

Actualizo la petición anterior. **Léela antes de empezar**, porque te ahorra la
parte más incómoda de lo que te pedí.

## Lo que cambia

En la nota anterior te decía que el botón tendría que buscar la promoción
pendiente, porque `notifications` no lleva ninguna referencia al registro. Eso
era trabajo mío mal repartido: lo he resuelto en la base.

**Ahora son dos llamadas RPC sin parámetros:**

```ts
// 1. ¿Hay algo que confirmar? Úsalo para decidir si muestras el botón
//    y para el texto. Devuelve 0, 1 o más filas.
const { data } = await supabase.rpc('cerebro_promo_pendiente');
// data[0] = { id, min_cup, max_cup, multiplicador, precio_gyd,
//             vigente_desde, vigente_hasta, resumen, hay_precio }

// 2. Confirmar. Sin id.
const { data } = await supabase.rpc('cerebro_promo_confirmar_pendiente',
                                    { p_quien: 'crm' });
// devuelve un texto: "confirmada: 600-1250 CUP x6"
```

Las dos son `SECURITY DEFINER` y tienen `GRANT EXECUTE ... TO authenticated`,
así que se pueden llamar desde el cliente sin más.

**El campo `resumen`** ya viene formateado para pintarlo tal cual:
`"600-1250 CUP x6, del 13/08 al 16/08 - 6200 GYD"`.

**Ojo con `hay_precio`.** Si viene `false`, el negocio no tiene precio definido
para ese monto y **confirmarla no sirve de nada**: el bot seguirá sin cotizar.
En ese caso, mejor que el botón no aparezca y se muestre el aviso de que falta
poner el precio.

## Lo que devuelve confirmar, y por qué

Tres respuestas posibles, y conviene enseñarlas tal cual al usuario:

- `"confirmada: 600-1250 CUP x6"` — bien
- `"no hay ninguna promocion pendiente de confirmar"` — alguien se te adelantó
- `"hay 2 promociones pendientes: confirmelas una a una, no se puede adivinar cual"`

El tercero es a propósito: **con dos candidatas la función no elige**. Es el
mismo criterio que usamos en el resolutor de operaciones — cuando hay
ambigüedad, nadie adivina. Si eso llega a pasar, hará falta un selector; hoy no
merece la pena porque nunca ha habido dos a la vez.

## Lo demás sigue igual

- Icono para el tipo `promo_etecsa` (sigue saliendo la campana genérica)
- El `<button>` que envuelve la tarjeta sigue siendo el punto incómodo: hay que
  reestructurar el `<li>` para meter un botón dentro

## Prioridad

**Sigue sin ser urgente.** La promoción actual (600-1250 CUP x6, del 13 al 16)
ya está confirmada por Osmany, así que el bot la anuncia desde hoy y la cotizará
el día 13 sin que tengas que hacer nada. Esto es para la próxima.

Y como siempre: `notifications/page.tsx` cuelga del shell del dashboard, todo en
`try/catch`, y desplegar fuera del horario del negocio.
