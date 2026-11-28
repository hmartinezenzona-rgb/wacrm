// Runs the notifier's "Filtrar cambio de etapa" code node (n8n `wGud0KGR6eMqqfMQ`) offline. Same pattern as
// `../vigilante/correr.ts`: the node body lives in `filtrar.jscode` and runs through `new Function` with stubs of
// `$input`, `$('Webhook cambio de deal')` and `require`.
// The `.jscode` extension is deliberate: prettier must not reformat a deployed payload.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** md5 of the node code as it stands (updated with every deliberate change). */
export const FILTRAR_MD5_ESPERADO = '724f1f26c01a1aaea05bf404373b6eee';

export const ORIGEN_FILTRAR = join(dirname(fileURLToPath(import.meta.url)), 'filtrar.jscode');

const SECRETO = 'secreto-de-prueba';

export type Salida = {
  json: { destino?: string; mensaje?: string; plantilla?: { name: string; params: string[] } };
};

/** One status change of an operation, as the DB webhook sends it, plus what "Leer secreto" adds. */
export function filtrar(
  record: Record<string, unknown>,
  oldRecord: Record<string, unknown>,
  extra: Record<string, unknown> = {}
): Salida[] {
  const codigo = readFileSync(ORIGEN_FILTRAR, 'utf8');
  const nodo = new Function('$input', '$', 'require', codigo) as (
    i: { first: () => { json: unknown } },
    $: (n: string) => { first: () => { json: unknown } },
    r: NodeRequire
  ) => Salida[];
  const webhook = {
    headers: { 'x-cerebro-secret': SECRETO },
    body: { type: 'UPDATE', table: 'remittance_operations', record, old_record: oldRecord },
  };
  return nodo(
    { first: () => ({ json: { secreto: SECRETO, ...extra } }) },
    (n: string) => {
      if (n !== 'Webhook cambio de deal') throw new Error(`node ${n} not stubbed`);
      return { first: () => ({ json: webhook }) };
    },
    createRequire(import.meta.url)
  );
}
