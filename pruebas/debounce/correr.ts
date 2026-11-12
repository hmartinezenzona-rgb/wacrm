// Runs the Cerebro "Evaluar completitud" code node (adaptive debounce) offline. Same pattern as
// `../notificador/correr.ts`: the node body lives in `evaluar-completitud.jscode` and runs through `new Function`
// with stubs of `$input` and `$runIndex`.
// The `.jscode` extension is deliberate: prettier must not reformat a deployed payload.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** md5 of the node code as it stands (updated with every deliberate change). */
export const COMPLETITUD_MD5_ESPERADO = 'e7958007';

export const ORIGEN_COMPLETITUD = join(dirname(fileURLToPath(import.meta.url)), 'evaluar-completitud.jscode');

export type Evento = { tipo: 'text' | 'image' | 'audio'; contenido?: string };

/** Pending batch (events in arrival order) -> whether the node asks for the extra wait. */
export function incompleto(eventos: Evento[], runIndex = 0): boolean {
  const codigo = readFileSync(ORIGEN_COMPLETITUD, 'utf8');
  const nodo = new Function('$input', '$runIndex', codigo) as (
    i: { all: () => { json: unknown }[] },
    r: number
  ) => { json: { id: number; incompleto: boolean } }[];
  const items = eventos.map((e, i) => ({ json: { id: i + 1, ...e } }));
  return nodo({ all: () => items }, runIndex)[0].json.incompleto;
}
