# Medir el efecto de la ventana de 20 s en el bot

**Cuándo:** a partir del **2026-10-29** (tres días desde el cambio del 2026-10-26).

## Qué se cambió
- `Esperar ventana`: 12 → 20 s (staging y producción).
- El camino de reintento (`Es reintento?`) ya no salta la espera: pasa por la misma puerta.

## Línea base (3 días antes del cambio)
| Métrica | Valor |
|---|---|
| Mensajes del cliente | 308 |
| Turnos (regla 30 s) | 196 |
| Respuestas del bot | 201 |
| Turnos con una respuesta | 118 |
| Turnos con varias | 36 |
| Turnos sin respuesta | 42 |
| Respuestas con el cliente escribiendo en los 12 s siguientes | 15 |
| Huecos entre mensajes del cliente: ≤12 s / 12–30 s / 30 s–2 min / >2 min | 64 / 48 / 79 / 84 |

## Qué medir
1. Mismo cuadro, última ventana de 3 días.
2. Respuestas que caen dentro de los **20 s** siguientes a un mensaje del cliente (debería ser ~0 salvo reintentos).
3. Reparto de huecos: cuántos mensajes pasan a agruparse tras subir la ventana.

## Cómo (consultas read-only)
Con `infra/db/correccion-produccion.sh <file.sql> --confirmar`:
- turnos y respuestas por turno (regla de 30 s entre mensajes del cliente);
- respuestas con mensaje del cliente a ≤20 s;
- distribución de huecos entre mensajes consecutivos del cliente.

## Esperado
- Menos respuestas por turno (por debajo de 201).
- Ninguna respuesta dentro de los 20 s posteriores al último mensaje, salvo el camino de reintento si apareciera.
- Aumento de mensajes agrupados en la banda 12–20 s.

## Si no mejora
Revisar: si el agente responde igual (Decisor decidiendo no hacer SKIP), si hay reintentos frecuentes, o si el hand-off entre ejecuciones no se está dando (mirar `session_events.processing_status`).
