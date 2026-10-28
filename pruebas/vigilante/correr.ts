// Runs the Etecsa promo watcher's code nodes (n8n `vk6aEa4bOZtl5xSz`) offline. Same pattern as
// `../partir/correr.ts`: each node body lives in a `.jscode` file ("Run Once for All Items") and runs
// through `new Function` with stubs of `$input` and `$('<node>')`.
// The `.jscode` extension is deliberate: prettier must not reformat a deployed payload.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));

/** md5 of each node's code as it stands (updated with every deliberate change). */
export const MD5_ESPERADO = {
  buscar: '43d51ec65cc1124a552350d40c2e22e2',
  parsear: '842d35469362276f2c0b5f4815aa3213',
};

export const ORIGEN = {
  buscar: join(AQUI, 'buscar.jscode'),
  parsear: join(AQUI, 'parsear.jscode'),
};

export type Item = { json: Record<string, unknown> };

type Nodos = Record<string, Item[]>;

function correr(origen: string, entrada: Item[], nodos: Nodos): Item[] {
  const codigo = readFileSync(origen, 'utf8');
  const nodo = new Function('$input', '$', codigo) as (
    i: { all: () => Item[]; first: () => Item },
    $: (n: string) => { all: () => Item[]; first: () => Item }
  ) => Item[];
  const ref = (items: Item[]) => ({ all: () => items, first: () => items[0] });
  return nodo(ref(entrada), (n: string) => {
    if (!(n in nodos)) throw new Error(`node ${n} not stubbed`);
    return ref(nodos[n]);
  });
}

/** "Buscar candidatos": input is the output of "Leer etecsa.cu" (one item). */
export function buscar(lectura: Item): Item[] {
  return correr(ORIGEN.buscar, [lectura], {});
}

/** "Parsear promocion": input is "Leer la promocion" (one item per candidate). */
export function parsear(paginas: Item[], candidatos: Item[]): Item[] {
  return correr(ORIGEN.parsear, paginas, { 'Buscar candidatos': candidatos });
}
