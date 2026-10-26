# Hermes: cifras reales en las tarjetas

## Objetivo
Que las cuatro tarjetas de ideas reflejen la realidad del día en vez de un dibujo.

## Fuentes (las mismas que usan el panel y Hermes)
- Cuadra el día: `hermes_cuadre_finanzas()` — completadas, líneas en Finanzas y sin línea.
- Sin responder: `hermes_sin_responder()` (migración 321) — conversaciones cuyo último mensaje es del cliente y no están cerradas.
- En incidencia: `crm_tablero_operaciones()` — cuenta e importe de las que están en `incident`.
- Semana: `hermes_cuadre_finanzas(hoy-6, hoy)` — facturado, invertido y retorno.

## Tareas
- [x] Migración 321 + ROLLBACK + aserción; aplicada en staging (`ALL PASS`).
- [x] `src/lib/hermes/vistazo.ts`: lee los cuatro bloques; cada uno falla por separado.
- [x] `GET /api/hermes/vistazo`: solo admin, lectura, cache 60 s.
- [x] Tarjetas con cifras reales y vuelta al dibujo si falta el dato.
- [ ] Aplicar la migración en producción (previa: SEGURO).
- [ ] Publicar el panel y verlo con datos reales.

## Comprobaciones
- Suite 3324 en verde; `tsc` limpio.
- `produccion-migracion.sh previa` → `VEREDICTO: SEGURO`.
