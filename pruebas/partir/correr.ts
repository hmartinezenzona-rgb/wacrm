// Runs the `Partir respuesta` code node offline. Same pattern as `../decisor/produccion/correr.ts`:
// the node source lives in `./partir.jscode` (an n8n Code node body, "Run Once for All Items") and is
// executed through `new Function` with a stub of `$input`.
// The `.jscode` extension is deliberate: prettier must not reformat a deployed payload.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** md5 of the node code as it stands (updated with every deliberate change). */
export const PARTIR_MD5_ESPERADO = '2d2e0fff395fcef3ba0aa8f943136f72';

export const ORIGEN_PARTIR = join(
  dirname(fileURLToPath(import.meta.url)),
  'partir.jscode'
);

export type ItemPartir = {
  json: Record<string, unknown> & {
    output?: unknown;
    opt_partir_respuesta?: unknown;
    partes?: string[];
    partes_n?: number;
  };
};

/** Runs the node over the given items and returns its output items. */
export function correrNodo(items: ItemPartir[]): ItemPartir[] {
  const codigo = readFileSync(ORIGEN_PARTIR, 'utf8');
  const nodo = new Function('$input', codigo) as (entrada: {
    all: () => ItemPartir[];
  }) => ItemPartir[];
  return nodo({ all: () => items });
}

/** Convenience: one reply text and the flag value; returns the parts the node produced. */
export function partir(texto: string, flag: string = 'si'): string[] {
  const salida = correrNodo([
    { json: { output: texto, opt_partir_respuesta: flag } },
  ]);
  return salida[0].json.partes ?? [];
}
