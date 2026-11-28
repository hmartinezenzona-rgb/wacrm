import { describe, it, expect } from 'vitest';

import { keyStatus, partitionKeys } from './roster';

/**
 * Estas pruebas fijan una decisión, no un detalle de presentación.
 *
 * El problema original era que las claves revocadas se quedaban apiladas
 * con las vivas y ensuciaban la lista. La primera solución fue borrar la
 * fila al revocar — y eso destruía el único registro de que la clave
 * existió, con qué permisos y cuándo se usó. Se descartó.
 *
 * La regla que queda: la fila SIEMPRE sobrevive; lo que cambia es dónde se
 * pinta. Si alguien vuelve a "limpiar" el listado quitando filas, esto lo
 * detiene.
 */

const AHORA = new Date('2026-09-03T12:00:00Z').getTime();
const clave = (p: Partial<{ revoked_at: string | null; expires_at: string | null }> = {}) => ({
  revoked_at: null,
  expires_at: null,
  ...p,
});

describe('keyStatus', () => {
  it('una clave sin revocar ni caducar está activa', () => {
    expect(keyStatus(clave(), AHORA)).toBe('active');
  });

  it('revoked_at manda sobre todo lo demás', () => {
    expect(keyStatus(clave({ revoked_at: '2026-09-01T00:00:00Z' }), AHORA)).toBe('revoked');
  });

  it('caducada no es lo mismo que revocada', () => {
    expect(keyStatus(clave({ expires_at: '2026-08-01T00:00:00Z' }), AHORA)).toBe('expired');
  });

  it('una fecha de caducidad futura no caduca nada', () => {
    expect(keyStatus(clave({ expires_at: '2027-01-01T00:00:00Z' }), AHORA)).toBe('active');
  });
});

describe('partitionKeys — qué se ve de entrada', () => {
  it('una clave activa va a la lista visible', () => {
    const k = clave();
    const { activas, revocadas } = partitionKeys([k], AHORA);
    expect(activas).toEqual([k]);
    expect(revocadas).toEqual([]);
  });

  it('una clave revocada NO va en la lista visible: va a la plegada', () => {
    const k = clave({ revoked_at: '2026-09-01T00:00:00Z' });
    const { activas, revocadas } = partitionKeys([k], AHORA);
    expect(activas).toEqual([]);
    expect(revocadas).toEqual([k]);
  });

  it('la clave revocada SIGUE ESTANDO: se puede pedir y se ve', () => {
    // El equivalente en datos de desplegar "Mostrar revocadas (N)".
    const k = clave({ revoked_at: '2026-09-01T00:00:00Z' });
    const { revocadas } = partitionKeys([k], AHORA);
    expect(revocadas).toHaveLength(1);
    expect(revocadas[0]).toBe(k);
  });

  it('una caducada se queda en la lista principal, no se pliega', () => {
    const k = clave({ expires_at: '2026-08-01T00:00:00Z' });
    const { activas, revocadas } = partitionKeys([k], AHORA);
    expect(activas).toEqual([k]);
    expect(revocadas).toEqual([]);
  });

  it('NINGUNA clave se pierde por el camino: el reparto conserva la traza', () => {
    // La invariante que protege la auditoría. Si alguien "limpia" la lista
    // descartando filas en vez de plegarlas, este test se cae.
    const claves = [
      clave(),
      clave({ revoked_at: '2026-09-01T00:00:00Z' }),
      clave({ expires_at: '2026-08-01T00:00:00Z' }),
      clave({ revoked_at: '2026-07-01T00:00:00Z', expires_at: '2026-06-01T00:00:00Z' }),
    ];
    const { activas, revocadas } = partitionKeys(claves, AHORA);
    expect(activas.length + revocadas.length).toBe(claves.length);
    for (const k of claves) {
      expect([...activas, ...revocadas]).toContain(k);
    }
  });

  it('conserva el orden dentro de cada grupo', () => {
    const a1 = clave();
    const r1 = clave({ revoked_at: '2026-09-01T00:00:00Z' });
    const a2 = clave();
    const r2 = clave({ revoked_at: '2026-09-02T00:00:00Z' });
    const { activas, revocadas } = partitionKeys([a1, r1, a2, r2], AHORA);
    expect(activas).toEqual([a1, a2]);
    expect(revocadas).toEqual([r1, r2]);
  });
});
