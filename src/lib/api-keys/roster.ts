// ============================================================
// Estado y reparto de las claves en el panel de Ajustes.
//
// Vivía dentro de `api-keys-settings.tsx`, donde no se podía probar sin
// montar el componente entero. Se saca aquí porque la regla que decide qué
// clave se ve y cuál no es justamente la que hay que blindar:
//
// Una clave revocada NO se borra. La fila es el único registro de que la
// clave existió, con qué permisos y cuándo se usó por última vez; borrarla
// destruye esa traza. Lo que se resolvió fue el problema de RUIDO —las
// revocadas se apilaban con las vivas—, y se resuelve plegándolas, no
// haciéndolas desaparecer.
// ============================================================

export type EstadoClave = 'active' | 'revoked' | 'expired';

/** Lo mínimo que hace falta para clasificar una clave. */
export interface ClaveClasificable {
  revoked_at: string | null;
  expires_at: string | null;
}

export function keyStatus(k: ClaveClasificable, ahora = Date.now()): EstadoClave {
  if (k.revoked_at) return 'revoked';
  if (k.expires_at && new Date(k.expires_at).getTime() <= ahora) return 'expired';
  return 'active';
}

/**
 * Parte el listado en lo que se ve de entrada y lo que va plegado.
 *
 * Una clave CADUCADA se queda en la lista principal a propósito: no es lo
 * mismo que una revocada. Su estado puede cambiar solo —renovando la fecha—
 * y esconderla sería esconder algo que el operador quizá tenga que arreglar.
 */
export function partitionKeys<T extends ClaveClasificable>(
  claves: readonly T[],
  ahora = Date.now(),
): { activas: T[]; revocadas: T[] } {
  const activas: T[] = [];
  const revocadas: T[] = [];
  for (const k of claves) {
    (keyStatus(k, ahora) === 'revoked' ? revocadas : activas).push(k);
  }
  return { activas, revocadas };
}
