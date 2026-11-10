// Runs the LIVE (production) `Decisor` code node offline. Sibling of `../correr.ts`, but pointed at
// `./decisor.jscode`, which is a verbatim copy of the node deployed in production (Oct-19 bot plus
// the fixes of 2026-10-27), a different lineage from the staging copy in the parent directory.
// The `.jscode` extension is deliberate: prettier must not reformat a deployed payload.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { Entradas, Salida } from '../correr';

export type { Entradas, Salida };

/** md5 of the node code as vendored from the live production workflow on 2026-10-28. */
export const DECISOR_PRODUCCION_MD5_VENDORIZADO =
  '747db79b70cab7dc043a37ebc5efc8f2';

/** md5 of the copy in this repo as it stands (updated with every deliberate change). */
export const DECISOR_PRODUCCION_MD5_ESPERADO =
  '97469eb2a5da7a61f68d2528d50a9a0b';

export const ORIGEN_PRODUCCION = join(
  dirname(fileURLToPath(import.meta.url)),
  'decisor.jscode'
);

type Fila = Record<string, unknown>;

const NEGOCIO_POR_DEFECTO = {
  negocio: { nombre: 'Negocio de Prueba' },
  app: { titular: 'Titular App', pay_merchant: '1111111' },
  agente: { titular: 'Titular Agente', cuenta: '2222222' },
};

// Only the fields the node reads, with values that keep it on the "nothing special" path.
const CTX_POR_DEFECTO = {
  horario_abre_min: 8 * 60,
  horario_cierra_min: 18 * 60,
  horario_abre_texto: '8:00 am',
  horario_cierra_texto: '6:00 pm',
};

const SNAPSHOT_POR_DEFECTO = {
  texto_completo: '',
  telefono: '5920000000',
  conversation_id: 'conv-prueba',
};

function stub(e: Entradas) {
  const tabla: Record<string, Fila> = {
    'Contexto conversacion': { ...CTX_POR_DEFECTO, ...(e.ctx ?? {}) },
    'Historial contacto': e.historial ?? {},
    'Snapshot final': { ...SNAPSHOT_POR_DEFECTO, ...(e.snapshot ?? {}) },
    'Cruzar deposito con MMG': e.mmg ?? {},
    'Merge beneficiario': e.beneficiario ?? {},
    'Ultima cotizacion': e.cotizacion ?? {},
  };
  const negocio = { ...NEGOCIO_POR_DEFECTO, ...(e.negocio ?? {}) };

  return (nombre: string) => {
    if (nombre === 'Datos del negocio') {
      return { params: { jsonOutput: JSON.stringify(negocio) } };
    }
    const json = tabla[nombre];
    if (json === undefined) {
      throw new Error(
        `el Decisor pidio un nodo que el arnes no stubea: ${nombre}`
      );
    }
    return { first: () => ({ json }) };
  };
}

/** Runs the live node and returns its single output item plus the parsed `- ...` note lines. */
export function correrDecisorProduccion(entradas: Entradas = {}): Salida {
  const codigo = readFileSync(ORIGEN_PRODUCCION, 'utf8');
  const nodo = new Function('$', codigo) as (
    dolar: ReturnType<typeof stub>
  ) => [{ json: Salida }];
  const salida = nodo(stub(entradas))[0].json;
  const mensaje = salida.mensaje ?? '';
  const notas = mensaje
    .split('\n')
    .filter((l) => l.startsWith('- '))
    .map((l) => l.slice(2));
  return { ...salida, notas };
}

/** The note that starts with `prefijo`, or undefined. */
export function nota(salida: Salida, prefijo: string): string | undefined {
  return salida.notas.find((n) => n.startsWith(prefijo));
}
