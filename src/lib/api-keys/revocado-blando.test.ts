// ============================================================
// El revocado es BLANDO, y tiene que seguir siéndolo.
//
// El 2-sep-2026 se cambió en staging a un borrado duro (`DELETE` de la fila)
// para resolver un problema de la interfaz: las claves revocadas se
// acumulaban en la lista. La auditoría posterior lo rechazó, porque esa fila
// es el único registro de que la clave existió, con qué permisos y cuándo se
// usó por última vez. El ruido visual se resuelve plegando la sección
// (ver `roster.ts`); la traza no se puede reconstruir.
//
// Estas pruebas fijan las dos mitades de esa decisión:
//   1. una clave revocada NO autentica — el efecto de seguridad;
//   2. la fila SIGUE EXISTIENDO — el efecto de auditoría.
// ============================================================

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// La fila que "hay en la tabla". Los tests la cambian antes de cada caso.
let filaEnLaTabla: Record<string, unknown> | null = null;
const maybeSingle = vi.fn(async () => ({ data: filaEnLaTabla, error: null }));

vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({
    from: () => ({
      select: () => ({
        eq: () => ({ maybeSingle }),
      }),
    }),
  }),
}));

const { findActiveKeyByHash } = await import('./store');

const FILA_BASE = {
  id: 'k-1',
  account_id: 'acc-1',
  created_by: 'u-1',
  name: 'Integración de facturación',
  scopes: ['contacts:read'],
  expires_at: null,
  revoked_at: null,
};

beforeEach(() => {
  filaEnLaTabla = { ...FILA_BASE };
});

describe('una clave revocada no autentica', () => {
  it('la clave viva sí resuelve', async () => {
    expect(await findActiveKeyByHash('hash')).toMatchObject({ id: 'k-1' });
  });

  it('con `revoked_at` puesto, la búsqueda devuelve null', async () => {
    filaEnLaTabla = { ...FILA_BASE, revoked_at: '2026-09-01T00:00:00Z' };
    expect(await findActiveKeyByHash('hash')).toBeNull();
  });

  it('la fila SIGUE en la tabla: se consultó y vino con datos', async () => {
    // Ésta es la mitad de auditoría. La búsqueda devuelve null por la
    // comprobación de liveness, no porque no haya fila: el registro de que
    // la clave existió —su nombre, sus permisos, cuándo se revocó— sigue ahí.
    filaEnLaTabla = { ...FILA_BASE, revoked_at: '2026-09-01T00:00:00Z' };
    await findActiveKeyByHash('hash');
    const { data } = await maybeSingle.mock.results.at(-1)!.value;
    expect(data).not.toBeNull();
    expect(data).toMatchObject({
      name: 'Integración de facturación',
      scopes: ['contacts:read'],
      revoked_at: '2026-09-01T00:00:00Z',
    });
  });

  it('una caducada tampoco autentica, y su fila también sobrevive', async () => {
    filaEnLaTabla = { ...FILA_BASE, expires_at: '2020-01-01T00:00:00Z' };
    expect(await findActiveKeyByHash('hash')).toBeNull();
    const { data } = await maybeSingle.mock.results.at(-1)!.value;
    expect(data).not.toBeNull();
  });
});

describe('el endpoint de revocar no borra la fila', () => {
  // Guard sobre el fuente, como `notes-untouched.test.ts`: vitest corre con
  // `environment: "node"` y el handler necesitaría media pila de Supabase y
  // de sesión para ejecutarse. Lo que hay que impedir es concreto y se lee
  // en el código.
  const fuente = readFileSync(
    join(process.cwd(), 'src/app/api/account/api-keys/[id]/route.ts'),
    'utf8',
  );

  it('marca `revoked_at` con un UPDATE', () => {
    expect(fuente).toMatch(/\.update\(\s*\{\s*revoked_at:/);
  });

  it('no llama a `.delete()` en ningún sitio', () => {
    expect(fuente).not.toMatch(/\.delete\s*\(/);
  });

  it('acota el UPDATE por cuenta, no sólo por id', () => {
    expect(fuente).toContain("eq('account_id'");
  });
});
