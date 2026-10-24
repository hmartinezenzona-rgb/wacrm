// Runs the REAL `Decisor` code node of the Cerebro workflow offline.
//
// Why this exists: the gold battery cannot test this node. `evaluar.py:montar_workflow` builds a
// temp workflow with only the webhook, `Contexto conversacion`, `Entrada`, the agent, the model and
// the tools — no `Decisor` — and every gold case carries its `[CONTEXTO]` baked into the message,
// recorded in August. So the battery replays whatever the node said back then, forever.
//
// `decisor.jscode` is the node's `jsCode`, verbatim. It is a bare script: top-level `const` and a
// trailing `return`, which is a syntax error in a module, so it is wrapped with `new Function`.
// The node only ever touches `$('Name').first().json` and `$('Datos del negocio').params.jsonOutput`.
//
// The `.jscode` extension is deliberate: it is a deployed payload, not project source. As `.js`,
// prettier reformatted all 1720 lines of it on 2026-10-18 and the md5 stopped matching the live
// workflow, destroying the one property that makes the copy useful — being comparable to n8n.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** md5 of the node code as vendored from n8n before any change (prod and staging agreed). */
export const DECISOR_MD5_AL_FIJARLO = 'c2ed1d13c177dc368fbfd63150e706e7';

/**
 * md5 of the copy in this repo as it stands. S4 (269, 2026-10-22): notes read ctx.servicio_resuelto; deployed to staging with the same change. S5b adds the declared-service tool names and the reconcile note for over-deposits. 277: reconcile note built from servicio_resuelto.reparto_planeado. P2: the reconcile note states facts only. Previous staging md5 8c421a94453c1f45cecbededbe96e892.
 * 2026-10-23 (291 follow-up): Mexico recipients count as a destination and a per-operation recipients note is added. 293: PARTES ACORDADAS note (agreed amount per part, what the registered deposit covers whole, shortfall).
 * Last deployed to staging `U52y1kSNvhgxvWeb` on 2026-10-20 had md5 af1e5e40124b678215f295b6736b1792.
 * A test asserts the file still hashes to this, so a formatter run or a half-applied edit fails
 * loudly instead of silently diverging from the workflow.
 */
export const DECISOR_MD5_ESPERADO = '18a0c643ede9d802fd1f858e12df7a19';

export const ORIGEN = join(
  dirname(fileURLToPath(import.meta.url)),
  'decisor.jscode'
);

type Fila = Record<string, unknown>;

export interface Entradas {
  /** `$('Contexto conversacion').first().json` */
  ctx?: Fila;
  /** `$('Historial contacto').first().json` */
  historial?: Fila;
  /** `$('Snapshot final').first().json` */
  snapshot?: Fila;
  /** `$('Cruzar deposito con MMG').first().json` */
  mmg?: Fila;
  /** `$('Merge beneficiario').first().json` */
  beneficiario?: Fila;
  /** `$('Ultima cotizacion').first().json` */
  cotizacion?: Fila;
  /** parsed object behind `$('Datos del negocio').params.jsonOutput` */
  negocio?: Fila;
}

export interface Salida {
  ruta: string;
  mensaje: string;
  telefono_e164: string;
  conversation_id: unknown;
  plan: Fila | null;
  /** the `- ...` note lines the node appended after the client's text */
  notas: string[];
}

const NEGOCIO_POR_DEFECTO = {
  negocio: { nombre: 'Negocio de Prueba' },
  app: { titular: 'Titular App', pay_merchant: '1111111' },
  agente: { titular: 'Titular Agente', cuenta: '2222222' },
};

// Only the fields the node actually reads, with values that keep it on the "nothing special is
// happening" path: business open, no deposit, no beneficiary, no service in progress.
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

/**
 * Runs the node and returns its single output item, plus the note lines parsed out of `mensaje`.
 * Notes are the lines the node appends under the `[CONTEXTO DEL SISTEMA ...]` header, one per `- `.
 */
export function correrDecisor(entradas: Entradas = {}): Salida {
  const codigo = readFileSync(ORIGEN, 'utf8');
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

/** The note that starts with `prefijo`, or undefined. Notes are long; match on their opening. */
export function nota(salida: Salida, prefijo: string): string | undefined {
  return salida.notas.find((n) => n.startsWith(prefijo));
}
