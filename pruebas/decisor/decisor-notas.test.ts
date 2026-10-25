// What the `Decisor` node is allowed to tell the model about a quote.
//
// The rule being enforced is the owner's (2026-10-18): "No adivines. Para cotizar hay que saber que
// quiere el cliente: si no lo sabes, preguntas." The node may decide which SIDE of the quote the
// amount sits on — that is readable from the phrasing — but it must NOT decide the destination
// currency when the client never said it, must not name a calculator that implies one, and must not
// dictate the sentence.
//
// Measured before writing these: with no rail known, the node emits
//   "CALCULO A HACER (ya resuelto por el sistema, no lo replantees): ... Usa calcular_envio con ese
//    numero. Al responder di: \"Por *X GYD* llegan *Y CUP* a Cuba.\""
// and the bot reproduces that sentence verbatim (gold cases reg-27065, reg-28021).
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  correrDecisor,
  DECISOR_MD5_ESPERADO,
  nota,
  ORIGEN,
  type Entradas,
} from './correr';

describe('la copia del nodo no puede derivar en silencio', () => {
  // On 2026-10-18 prettier reformatted this file (then named .js) and its md5 stopped matching the
  // deployed workflow, which is the only thing that makes a vendored copy worth having.
  it('mantiene la huella con la que se desplego a staging', () => {
    const md5 = createHash('md5').update(readFileSync(ORIGEN)).digest('hex');
    expect(md5).toBe(DECISOR_MD5_ESPERADO);
  });
});

/** The note that tells the model which direction the quote goes. Renamed by the fix. */
function notaDeCalculo(
  salida: ReturnType<typeof correrDecisor>
): string | undefined {
  return nota(salida, 'LADO DEL MONTO') ?? nota(salida, 'CALCULO A HACER');
}

function turno(texto: string, extra: Entradas = {}) {
  return correrDecisor({
    ...extra,
    snapshot: { ...(extra.snapshot ?? {}), texto_completo: texto },
  });
}

describe('sin via conocida, el nodo no puede elegir la moneda de destino', () => {
  it('"cuanto llega si envio 30 mil" no ordena calcular_envio ni nombra CUP', () => {
    const n = notaDeCalculo(turno('cuanto llega si envio 30 mil?'));
    expect(n).toBeDefined();
    expect(n).not.toMatch(/calcular_envio/);
    expect(n).not.toMatch(/CUP/);
  });

  it('"cuanto llega si envio 30 mil" no dicta la frase de respuesta', () => {
    const n = notaDeCalculo(turno('cuanto llega si envio 30 mil?'));
    expect(n).not.toMatch(/Al responder di/i);
    expect(n).not.toMatch(/llegan \*/);
  });

  it('manda preguntar la via antes de cotizar', () => {
    const n = notaDeCalculo(turno('cuanto llega si envio 30 mil?'));
    expect(n).toMatch(/NO SE SABE|no se sabe/);
    expect(n).toMatch(/pregunta/i);
  });

  it('"para que lleguen 60 mil" tampoco asume CUP ni calcular_inverso', () => {
    const n = notaDeCalculo(
      turno('cuanto tengo que depositar para que lleguen 60 mil?')
    );
    expect(n).toBeDefined();
    expect(n).not.toMatch(/calcular_inverso/);
    expect(n).not.toMatch(/CUP/);
  });
});

describe('el LADO del monto sigue decidiendolo el codigo', () => {
  it('"cuanto llega" = el monto es lo que DEPOSITA', () => {
    const n = notaDeCalculo(turno('cuanto llega si envio 30 mil?'));
    expect(n).toMatch(/DEPOSITA/);
  });

  it('"para que lleguen" = el monto es el de DESTINO', () => {
    const n = notaDeCalculo(
      turno('cuanto tengo que depositar para que lleguen 60 mil?')
    );
    expect(n).toMatch(/DESTINO/);
  });
});

describe('con la via ya elegida, la nota si nombra su calculador', () => {
  it('Zelle: usa el calculador de dolares con su via, nunca calcular_envio', () => {
    const n = notaDeCalculo(
      turno('cuanto llega si envio 30 mil?', {
        ctx: { riel_operacion: 'zelle' },
      })
    );
    expect(n).toBeDefined();
    expect(n).toMatch(/calcular_usd_desde_gyd/);
    expect(n).toMatch(/zelle/i);
    expect(n).not.toMatch(/calcular_envio/);
  });

  it('tarjeta en CUP: ahi si corresponde calcular_envio y hablar de CUP', () => {
    const n = notaDeCalculo(
      turno('cuanto llega si envio 30 mil?', {
        ctx: { riel_operacion: 'cuban_card' },
      })
    );
    expect(n).toBeDefined();
    expect(n).toMatch(/calcular_envio/);
    expect(n).toMatch(/CUP/);
  });
});

describe('el contexto no puede llevar dos ordenes opuestas', () => {
  // Lines 930-934 of the node record this lesson from 2026-08-10: "Dos ordenes opuestas en el mismo
  // contexto: el modelo se quedo con la que prometia. El fallo era del contexto, no del modelo."
  it('si otra nota dice que no se sabe la via, la de calculo no nombra una moneda de destino', () => {
    const salida = turno('cuanto llega si envio 30 mil?');
    const sinVia = nota(salida, 'TODAVIA NO SE SABE POR QUE VIA RECIBE');
    if (!sinVia) return; // esa nota tiene sus propias guardas; si no salio, no hay contradiccion
    expect(notaDeCalculo(salida)).not.toMatch(/CUP|USD/);
  });
});

describe('la remesa no lleva reloj (decision del dueno, 2026-10-03)', () => {
  // "una remesa puede hacerse rapido o demorar un poco, entonces el 'en breve' promete algo que la
  // mayoria de veces no se cumple". La forma decidida no promete CUANDO, promete AVISO.
  // El nodo tenia 6 notas que ordenaban justo lo contrario: "dile que en breve le confirman".
  const ORDENA_TIEMPO =
    /(dile|digale|di) que[^.]{0,60}\b(en breve|enseguida|en unos minutos|hoy mismo)\b|\bconfirman? en breve\b/i;

  it('ninguna nota ORDENA prometer tiempo, en ningun turno', () => {
    const turnos: Array<[string, Entradas]> = [
      [
        'comprobante',
        { snapshot: { texto_completo: 'ahi va el comprobante' } },
      ],
      ['como va lo mio', { snapshot: { texto_completo: 'como va lo mio?' } }],
      [
        'cuanto llega',
        { snapshot: { texto_completo: 'cuanto llega si envio 30 mil?' } },
      ],
      ['gracias', { snapshot: { texto_completo: 'ok gracias' } }],
      [
        'recarga',
        { snapshot: { texto_completo: 'quiero una recarga de 500 CUP' } },
      ],
    ];
    for (const [etiqueta, e] of turnos) {
      for (const n of correrDecisor(e).notas) {
        expect(n, `${etiqueta}: ${n.slice(0, 90)}`).not.toMatch(ORDENA_TIEMPO);
      }
    }
  });

  it('las prohibiciones de prometer tiempo siguen en pie', () => {
    const codigo = readFileSync(ORIGEN, 'utf8');
    expect(codigo).toMatch(
      /PROHIBIDO decir "en breve le hacemos la transferencia"/
    );
  });
});

describe('el gate 83 no se toca: con la moneda pegada al monto la via SI se sabe', () => {
  it('"quiero enviar 15 mil CUP" sigue siendo monto de destino con calcular_inverso', () => {
    const n = nota(turno('quiero enviar 15 mil CUP'), 'MONTO DE DESTINO');
    expect(n).toBeDefined();
    expect(n).toMatch(/calcular_inverso/);
  });

  it('"quiero enviar 100 usd por zelle" sigue yendo a calcular_usd con via=zelle', () => {
    const n = nota(
      turno('quiero enviar 100 usd por zelle'),
      'MONTO DE DESTINO'
    );
    expect(n).toBeDefined();
    expect(n).toMatch(/calcular_usd\(100, via=zelle\)/);
  });
});

describe('un deposito de mas por un segundo servicio no se trata como error del cliente', () => {
  // 2026-10-20 (f8b7779c): the customer deposited 24,400 for 18,200 (Clasica) + 6,200 (recarga). The
  // node told the model "ves que mando mas de lo que habiais hablado", which is wrong when the extra
  // money is a second service. The tool `repartir_envio` (migration 255) splits one deposit.
  const cruceDeMas = {
    resultado: 'verificado_de_mas',
    objetivo: 18200,
    depositado: 24400,
    saldo: -6200,
  };
  function conComprobante(
    ctx: Entradas['ctx'],
    previos = '',
    texto = 'ahi va'
  ) {
    return correrDecisor({
      ctx: { riel_operacion: 'clasica', muestra_idioma: previos, ...ctx },
      snapshot: {
        texto_completo: texto,
        comprobante: {
          estado: 'LEGIBLE',
          monto: 24400,
          moneda: 'GYD',
          alertas: [],
        },
      },
      mmg: cruceDeMas,
    });
  }
  const PREFIJO = 'EL CLIENTE DEPOSITO MAS DE LO QUE DIJO';

  it('sin segundo servicio, la nota sigue siendo la de siempre', () => {
    const n = nota(conComprobante({}), PREFIJO);
    expect(n).toBeDefined();
    expect(n).toMatch(/mando mas de lo que habiais hablado/);
    expect(n).not.toMatch(/repartir_envio/);
  });

  it('si ya hablo de una recarga, manda confirmar el reparto y llamar repartir_envio', () => {
    const n = nota(
      conComprobante({}, 'quiero enviar 70 usd y ademas una recarga de 6200'),
      PREFIJO
    );
    expect(n).toBeDefined();
    expect(n).toMatch(/repartir_envio/);
    expect(n).toMatch(/recarga/i);
    expect(n).toMatch(/18,200/);
    expect(n).toMatch(/24,400/);
  });

  it('no le dice al cliente que mando de mas ni deja la orden de esperar a una persona', () => {
    const n = nota(
      conComprobante({}, 'tambien quiero una recarga etecsa'),
      PREFIJO
    ) as string;
    expect(n).not.toMatch(/mando mas de lo que habiais hablado/);
    expect(n).not.toMatch(/una persona le confirma/);
    expect(n).toMatch(/NO le digas que mando de mas/i);
  });

  it('lo detecta tambien en el mensaje de este turno y en combo, visa o saldo movil', () => {
    for (const [previos, texto, servicio] of [
      ['', 'y otros 6200 para una recarga', 'recarga'],
      ['', 'tambien un combo de comida', 'combo'],
      ['quiero extender mi visa tambien', '', 'visa'],
      ['', 'y 6200 de saldo movil', 'saldo'],
    ]) {
      const n = nota(conComprobante({}, previos, texto), PREFIJO);
      expect(n, servicio).toMatch(/repartir_envio/);
    }
  });

  it('usa el indicador de la base cuando la conversacion ya tiene una recarga abierta', () => {
    const n = nota(conComprobante({ recarga_en_curso: true }), PREFIJO);
    expect(n).toMatch(/repartir_envio/);
  });

  it('si el servicio de la propia operacion es la recarga, no cuenta como segundo servicio', () => {
    const n = nota(
      conComprobante(
        { riel_operacion: 'recarga', recarga_en_curso: true },
        'quiero una recarga'
      ),
      PREFIJO
    );
    expect(n).toBeDefined();
    expect(n).not.toMatch(/repartir_envio/);
  });
});

describe('un envio mixto (un deposito repartido entre servicios) se lo dice al modelo', () => {
  // S6: the grouped operations come from `Contexto conversacion` as `envio_mixto`
  // ({ total, partes: [{ servicio, monto_gyd, destino, moneda, status }] }, NULL when ungrouped).
  const envioMixto = {
    total: 24400,
    partes: [
      {
        servicio: 'clasica',
        monto_gyd: 18200,
        destino: 70,
        moneda: 'USD',
        status: 'ready_to_transfer',
      },
      {
        servicio: 'recarga',
        monto_gyd: 6200,
        destino: null,
        moneda: null,
        status: 'collecting_information',
      },
    ],
  };
  const PREFIJO_MIXTO = 'ENVIO MIXTO';

  it('agrupado: lista cada servicio con su parte, el total y que es UN solo deposito', () => {
    const n = nota(
      correrDecisor({
        ctx: { riel_operacion: 'clasica', envio_mixto: envioMixto },
        snapshot: { texto_completo: 'ya lo mande' },
      }),
      PREFIJO_MIXTO
    ) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/clasica[^,;]*18,200/);
    expect(n).toMatch(/70 USD/);
    expect(n).toMatch(/recarga[^,;]*6,200/);
    expect(n).toMatch(/24,400/);
    expect(n).toMatch(/UN SOLO deposito/i);
  });

  it('manda tratar cada servicio por separado y repartir solo si el cliente cambia el reparto', () => {
    const n = nota(
      correrDecisor({
        ctx: { envio_mixto: envioMixto },
        snapshot: { texto_completo: 'hola' },
      }),
      PREFIJO_MIXTO
    ) as string;
    expect(n).toMatch(/NO es una sola remesa/i);
    expect(n).toMatch(/NO le digas que mando de mas/i);
    expect(n).toMatch(/tarjeta/i);
    expect(n).toMatch(/numero de Cuba|celular/i);
    expect(n).toMatch(/repartir_envio/);
    expect(n).toMatch(/solo si el cliente cambia/i);
  });

  it('sin grupo no hay nota de envio mixto', () => {
    for (const envio_mixto of [undefined, null]) {
      const s = correrDecisor({
        ctx: { riel_operacion: 'clasica', envio_mixto },
        snapshot: { texto_completo: 'hola' },
      });
      expect(nota(s, PREFIJO_MIXTO)).toBeUndefined();
    }
  });

  it('agrupado con un deposito de mas: nunca dice que mando de mas', () => {
    const s = correrDecisor({
      ctx: { riel_operacion: 'clasica', envio_mixto: envioMixto },
      snapshot: {
        texto_completo: 'ahi va',
        comprobante: {
          estado: 'LEGIBLE',
          monto: 30000,
          moneda: 'GYD',
          alertas: [],
        },
      },
      mmg: {
        resultado: 'verificado_de_mas',
        objetivo: 24400,
        depositado: 30000,
        saldo: -5600,
      },
    });
    const n = nota(s, 'EL CLIENTE DEPOSITO MAS DE LO QUE DIJO') as string;
    expect(n).toBeDefined();
    expect(n).not.toMatch(/mando mas de lo que habiais hablado/);
    expect(n).toMatch(/NO le digas que mando de mas/i);
    expect(n).toMatch(/repartir_envio/);
  });
});

describe('ausencia temporal (away mode): aviso solo con el negocio abierto', () => {
  const AUSENCIA = {
    motivo: 'en una reunion',
    hasta: '2026-10-21T19:00:00Z',
    hasta_texto: 'a las 3:00 pm',
    por: 'dueno',
  };
  // The node reads the process clock in America/Guyana (UTC-4). Wednesday 2026-10-21.
  const ABIERTO = '2026-10-21T15:00:00Z'; // 11:00 Guyana
  const CERRADO = '2026-10-21T07:00:00Z'; // 03:00 Guyana, before opening

  function a(hora: string, ce: unknown, extra: Entradas = {}) {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(hora));
    try {
      return correrDecisor({
        ...extra,
        ctx: { ...(extra.ctx ?? {}), cierre_especial: ce },
      });
    } finally {
      vi.useRealTimers();
    }
  }

  afterEach(() => {
    vi.useRealTimers();
  });

  it('abierto + ausencia: una nota con motivo, hasta_texto y sigue atendiendo', () => {
    const n = nota(a(ABIERTO, { ausencia: AUSENCIA }), 'AUSENCIA TEMPORAL');
    expect(n).toBeDefined();
    expect(n).toContain('en una reunion');
    expect(n).toContain('a las 3:00 pm');
    expect(n).toContain('SIGUE ATENDIENDO NORMAL');
    expect(n).toMatch(/PROHIBIDO decir "en breve"/);
    // Owner 2026-10-22: the ones away are the managers, not the assistant that keeps answering.
    expect(n).toContain('los encargados no estan disponibles');
    expect(n).toContain('regresan a las 3:00 pm');
    expect(n).not.toContain('no estamos');
  });

  it('abierto + por_cerrar + ausencia: salen las dos notas', () => {
    const s = a(ABIERTO, { ausencia: AUSENCIA }, { ctx: { por_cerrar: true } });
    expect(nota(s, 'PROXIMO A CERRAR')).toBeDefined();
    expect(nota(s, 'AUSENCIA TEMPORAL')).toBeDefined();
  });

  it('fuera de horario + ausencia: no hay nota de ausencia', () => {
    const s = a(CERRADO, { ausencia: AUSENCIA });
    expect(nota(s, 'FUERA DE HORARIO')).toBeDefined();
    expect(nota(s, 'AUSENCIA TEMPORAL')).toBeUndefined();
  });

  it('dia cerrado + ausencia: no hay nota de ausencia', () => {
    const s = a(ABIERTO, { hoy_motivo: 'feriado', ausencia: AUSENCIA });
    expect(nota(s, 'FUERA DE HORARIO')).toBeDefined();
    expect(nota(s, 'AUSENCIA TEMPORAL')).toBeUndefined();
  });

  it.each([
    ['texto', 'ausente'],
    ['objeto vacio', {}],
    ['sin hasta_texto', { motivo: 'en una reunion' }],
    ['sin motivo', { hasta_texto: 'a las 3:00 pm' }],
  ])('ausencia mal formada (%s): sin nota y sin error', (_n, aus) => {
    const s = a(ABIERTO, { ausencia: aus });
    expect(nota(s, 'AUSENCIA TEMPORAL')).toBeUndefined();
  });

  it('ausencia null: las notas son identicas a las de sin ausencia', () => {
    const con = a(ABIERTO, { ausencia: null });
    const sin = a(ABIERTO, {});
    expect(con.notas).toEqual(sin.notas);
    expect(nota(con, 'AUSENCIA TEMPORAL')).toBeUndefined();
  });
});

describe('S4: las notas de servicio salen SOLO del estado resuelto (servicio_resuelto)', () => {
  // The database resolver (265 v2) is the single state: operations, the agent's declared intent, deposit coverage.
  // Legacy fields (riel_operacion, recarga_en_curso, servicio_pendiente...) stay one release as aliases.
  const resuelto = (extra: Record<string, unknown> = {}) => ({
    version: 2,
    en_curso: null as string | null,
    servicio: null as string | null,
    accion: 'ninguna',
    permitido: true,
    motivo: 'sin_cambio',
    mensaje: null,
    minimo_gyd: null,
    faltante_gyd: null,
    operaciones: [] as unknown[],
    adicionales: [] as unknown[],
    evidencia: { declarado: null, deposito: 0 },
    ...extra,
  });
  const op = (servicio: string, status: string, extra = {}) => ({
    id: 'op-1',
    servicio,
    rail: servicio,
    status,
    ...extra,
  });

  it('una recarga resuelta abre la nota OPERACION EN CURSO sin ningun campo legacy', () => {
    const s = correrDecisor({
      ctx: {
        servicio_resuelto: resuelto({
          en_curso: 'recarga',
          operaciones: [op('recarga', 'awaiting_deposit')],
        }),
      },
    });
    expect(nota(s, 'OPERACION EN CURSO: RECARGA')).toBeDefined();
  });

  it('el estado resuelto manda sobre los alias legacy que lo contradicen', () => {
    const s = correrDecisor({
      ctx: {
        recarga_en_curso: true,
        riel_operacion: 'recarga',
        servicio_pendiente: 'zelle',
        servicio_resuelto: resuelto({
          en_curso: 'clasica',
          operaciones: [op('clasica', 'awaiting_deposit')],
        }),
      },
    });
    expect(nota(s, 'OPERACION EN CURSO: RECARGA')).toBeUndefined();
    expect(nota(s, 'EL CLIENTE YA ELIGIO')).toBeUndefined();
    const via = nota(s, 'VIA ACTUAL DE LA OPERACION') as string;
    expect(via).toMatch(/Clasica/);
    expect(via).toMatch(/cambiar_servicio/);
    expect(via).toMatch(/agregar_servicio/);
  });

  it('el estado real del envio sale de la operacion resuelta, no del historial', () => {
    const s = correrDecisor({
      ctx: {
        servicio_resuelto: resuelto({
          en_curso: 'cuban_card',
          operaciones: [op('cuban_card', 'deposit_verification')],
        }),
      },
    });
    const n = nota(s, 'ESTADO REAL DEL ENVIO EN CURSO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/EN VERIFICACION/);
  });

  it('un servicio declarado sin operacion se dice como declarado, no como servicio_pendiente', () => {
    const s = correrDecisor({
      ctx: {
        servicio_pendiente: 'efectivo',
        servicio_resuelto: resuelto({ evidencia: { declarado: 'recarga', deposito: 0 } }),
      },
    });
    const n = nota(s, 'EL CLIENTE YA DECLARO') as string;
    expect(n).toMatch(/recarga/);
    expect(nota(s, 'EL CLIENTE YA ELIGIO')).toBeUndefined();
  });

  it('SERVICIO POR CONFIRMAR cuando el deposito no cubre el servicio declarado', () => {
    const s = correrDecisor({
      ctx: {
        servicio_resuelto: resuelto({
          en_curso: 'cuban_card',
          servicio: 'zelle',
          permitido: false,
          motivo: 'deposito_bajo_minimo',
          mensaje: 'No alcanza para Zelle: el mínimo es 13,000 GYD y faltan 5,000 GYD.',
          minimo_gyd: 13000,
          faltante_gyd: 5000,
          operaciones: [op('cuban_card', 'awaiting_deposit')],
        }),
      },
    });
    const n = nota(s, 'SERVICIO POR CONFIRMAR') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/13,000/);
    expect(n).toMatch(/5,000/);
    expect(n).toMatch(/PROHIBIDO.*(confirmar|decir que ya cambio)/i);
  });

  it('sin decision pendiente no hay nota SERVICIO POR CONFIRMAR', () => {
    const s = correrDecisor({
      ctx: { servicio_resuelto: resuelto({ en_curso: 'zelle', operaciones: [op('zelle', 'awaiting_deposit')] }) },
    });
    expect(nota(s, 'SERVICIO POR CONFIRMAR')).toBeUndefined();
  });

  it('sin servicio_resuelto los alias legacy siguen funcionando (una version)', () => {
    const s = correrDecisor({ ctx: { riel_operacion: 'zelle' } });
    expect(nota(s, 'VIA ACTUAL DE LA OPERACION')).toMatch(/Zelle/);
  });
});

describe('S4: un envio de varias partes cuyo deposito verificado no cuadra pregunta que parte cambia (Marlene 4afda26a)', () => {
  // Deposit 71,200 = Mexico 100 USD (26,000) + cash 29,000 + messenger 1,200 + card 5,000 + 10,000. The customer typed
  // 150 USD for Mexico (39,000), so the agreed total is 84,200 and the bank verified 13,000 less. The bot said
  // "se transfiere el equivalente"; it must reconcile the parts and ASK.
  const partes = [
    { servicio: 'mexico', monto_gyd: 39000, usd: 150, moneda: 'MXN', status: 'awaiting_deposit' },
    { servicio: 'efectivo_usd', monto_gyd: 29000, usd: 112, moneda: 'USD', status: 'awaiting_deposit' },
    { servicio: 'mensajeria', monto_gyd: 1200, moneda: 'GYD', status: 'awaiting_deposit' },
    { servicio: 'cuban_card', monto_gyd: 5000, moneda: 'CUP', status: 'awaiting_deposit' },
    { servicio: 'cuban_card', monto_gyd: 10000, moneda: 'CUP', status: 'awaiting_deposit' },
  ];
  const marlene = () =>
    correrDecisor({
      ctx: { riel_operacion: 'mexico', envio_mixto: { total: 84200, partes } },
      snapshot: {
        texto_completo: 'ahi va',
        comprobante: { estado: 'LEGIBLE', monto: 71200, moneda: 'GYD', alertas: [] },
      },
      mmg: { resultado: 'verificado_incompleto', objetivo: 84200, depositado: 71200, saldo: 13000 },
    });

  it('propone la parte que cuadra exacto y pide confirmacion', () => {
    const n = nota(marlene(), 'DEPOSITO DISTINTO DE LO ACORDADO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/71,200/);
    expect(n).toMatch(/84,200/);
    expect(n).toMatch(/mexico/i);
    expect(n).toMatch(/150 USD/);
    expect(n).toMatch(/100 USD/);
    expect(n).not.toMatch(/PREGUNTA|sin decidirlo|PROHIBIDO/); // P2: facts only, the bot decides with the customer
  });

  it('prohibe decir que se transfiere el equivalente y la nota de "quedas esperando el resto"', () => {
    const s = marlene();
    const n = nota(s, 'DEPOSITO DISTINTO DE LO ACORDADO') as string;
    expect(n).toMatch(/nada se ha transferido ni repartido/i);
    expect(nota(s, 'RECIBIDO Y VERIFICADO CONTRA EL BANCO, PERO EL ENVIO TODAVIA NO ESTA COMPLETO')).toBeUndefined();
  });

  it('con una sola parte conserva la nota de siempre', () => {
    const s = correrDecisor({
      ctx: { riel_operacion: 'clasica' },
      snapshot: {
        texto_completo: 'ahi va',
        comprobante: { estado: 'LEGIBLE', monto: 10000, moneda: 'GYD', alertas: [] },
      },
      mmg: { resultado: 'verificado_incompleto', objetivo: 18200, depositado: 10000, saldo: 8200 },
    });
    expect(nota(s, 'RECIBIDO Y VERIFICADO CONTRA EL BANCO, PERO EL ENVIO TODAVIA NO ESTA COMPLETO')).toBeDefined();
    expect(nota(s, 'DEPOSITO DISTINTO DE LO ACORDADO')).toBeUndefined();
  });
});

describe('S5b: el servicio declarado decide que herramienta de datos se nombra', () => {
  const declarado = (svc: string) => ({
    version: 2,
    en_curso: null,
    servicio: null,
    accion: 'ninguna',
    permitido: true,
    motivo: 'sin_cambio',
    mensaje: null,
    operaciones: [],
    adicionales: [],
    evidencia: { declarado: svc, deposito: 0 },
  });

  it('recarga declarada con un numero suelto: registrar_numeros_recarga, nunca gestionar_beneficiario con el celular', () => {
    const s = correrDecisor({
      ctx: { servicio_resuelto: declarado('recarga') },
      snapshot: { texto_completo: '55599180', celular: '55599180' },
    });
    const n = nota(s, 'TODAVIA NO HAY BENEFICIARIO REGISTRADO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/registrar_numeros_recarga/);
    expect(n).not.toMatch(/gestionar_beneficiario con el celular/);
  });

  it('mexico declarado: nombra registrar_destinatario_mexico y no pide tarjeta', () => {
    const s = correrDecisor({
      ctx: { servicio_resuelto: declarado('mexico') },
      snapshot: { texto_completo: '55599180', celular: '55599180' },
    });
    const n = nota(s, 'TODAVIA NO HAY BENEFICIARIO REGISTRADO') as string;
    expect(n).toMatch(/registrar_destinatario_mexico/);
    expect(n).not.toMatch(/gestionar_beneficiario/);
  });
});

describe('S5b: el deposito que no cuadra con un envio de varias partes se reconcilia tambien de mas y sin parte exacta', () => {
  const conComprobante = (partes: unknown[], mmg: Record<string, unknown>, monto: number) =>
    correrDecisor({
      ctx: { riel_operacion: 'mexico', envio_mixto: { total: 1, partes } },
      snapshot: {
        texto_completo: 'ahi va',
        comprobante: { estado: 'LEGIBLE', monto, moneda: 'GYD', alertas: [] },
      },
      mmg,
    });
  const P = 'DEPOSITO DISTINTO DE LO ACORDADO';

  it('deposito de mas: si una parte absorbe la diferencia en USD enteros, la propone y pregunta', () => {
    const partes = [
      { servicio: 'mexico', monto_gyd: 26000, usd: 100, status: 'awaiting_deposit' },
      { servicio: 'efectivo_usd', monto_gyd: 29000, usd: 100, status: 'awaiting_deposit' },
    ];
    const s = conComprobante(
      partes,
      { resultado: 'verificado_de_mas', objetivo: 55000, depositado: 68000, saldo: -13000 },
      68000
    );
    const n = nota(s, P) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/150 USD/);
    expect(n).not.toMatch(/PREGUNTA|sin decidirlo|PROHIBIDO/); // P2: facts only, the bot decides with the customer
    expect(n).toMatch(/nada se ha transferido ni repartido/i);
  });

  it('deposito corto sin parte exacta: igual pregunta cual parte cambia, sin prometer ni esperar el resto', () => {
    const partes = [
      { servicio: 'mexico', monto_gyd: 39000, usd: 150, status: 'awaiting_deposit' },
      { servicio: 'cuban_card', monto_gyd: 5000, status: 'awaiting_deposit' },
    ];
    const s = conComprobante(
      partes,
      { resultado: 'verificado_incompleto', objetivo: 44000, depositado: 42200, saldo: 1800 },
      42200
    );
    const n = nota(s, P) as string;
    expect(n).toBeDefined();
    expect(n).not.toMatch(/PREGUNTA|sin decidirlo|PROHIBIDO/); // P2: facts only, the bot decides with the customer
    expect(n).toMatch(/nada se ha transferido ni repartido/i);
    expect(nota(s, 'RECIBIDO Y VERIFICADO CONTRA EL BANCO, PERO EL ENVIO TODAVIA NO ESTA COMPLETO')).toBeUndefined();
  });
});

describe('277: la nota de reconciliacion sale del reparto planeado (servicio_resuelto.reparto_planeado)', () => {
  const partes = [
    { servicio: 'mexico', monto_gyd: 39000, usd: 150 },
    { servicio: 'efectivo_usd', monto_gyd: 29000, usd: 100 },
    { servicio: 'cuban_card', monto_gyd: 5000, usd: null },
  ];
  const plan = (deposito: number | null, extra: Record<string, unknown> = {}) => ({
    version: 2,
    en_curso: 'mexico',
    servicio: 'mexico',
    accion: 'ninguna',
    permitido: true,
    motivo: 'sin_cambio',
    mensaje: 'x',
    operaciones: [],
    adicionales: [],
    evidencia: { declarado: null, deposito: deposito ?? 0 },
    reparto_planeado: {
      partes,
      total_gyd: 73000,
      deposito_gyd: deposito,
      diferencia_gyd: deposito === null ? null : deposito - 73000,
      coincide: deposito === 73000,
      ...extra,
    },
  });
  const P = 'DEPOSITO DISTINTO DE LO ACORDADO';
  const turno = (d: number | null) => correrDecisor({ ctx: { servicio_resuelto: plan(d) } });

  it('deposito corto ya registrado: propone la parte que cuadra y pregunta', () => {
    const n = nota(turno(60000), P) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/60,000/);
    expect(n).toMatch(/73,000/);
    expect(n).toMatch(/100 USD/);
    expect(n).toMatch(/150/);
    expect(n).not.toMatch(/PREGUNTA|sin decidirlo|PROHIBIDO/); // P2: facts only, the bot decides with the customer
    expect(n).toMatch(/nada se ha transferido ni repartido/i);
  });

  it('deposito de mas: tambien reconcilia', () => {
    const n = nota(turno(86000), P) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/de mas/);
    expect(n).toMatch(/200 USD/);
  });

  it('sin parte exacta igual pregunta cual parte cambia', () => {
    const n = nota(turno(71200), P) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/Ninguna parte sola cuadra/);
    expect(n).not.toMatch(/PREGUNTA|sin decidirlo|PROHIBIDO/); // P2: facts only, the bot decides with the customer
  });

  it('si coincide, o no hay deposito todavia, no hay nota', () => {
    expect(nota(turno(73000), P)).toBeUndefined();
    expect(nota(turno(null), P)).toBeUndefined();
  });

  it('con comprobante este turno usa las partes planeadas y la nota sale una sola vez', () => {
    const s = correrDecisor({
      ctx: { servicio_resuelto: plan(60000) },
      snapshot: {
        texto_completo: 'ahi va',
        comprobante: { estado: 'LEGIBLE', monto: 60000, moneda: 'GYD', alertas: [] },
      },
      mmg: { resultado: 'verificado_incompleto', objetivo: 73000, depositado: 60000, saldo: 13000 },
    });
    expect(s.notas.filter((n) => n.startsWith(P)).length).toBe(1);
    expect(nota(s, 'RECIBIDO Y VERIFICADO CONTRA EL BANCO, PERO EL ENVIO TODAVIA NO ESTA COMPLETO')).toBeUndefined();
    expect(nota(s, P)).toMatch(/100 USD/);
  });
});


describe('P2: la nota de reconciliacion solo da hechos (partes cubiertas, pendientes, importes)', () => {
  const partes = [
    { servicio: 'mexico', monto_gyd: 39000, usd: 150 },
    { servicio: 'efectivo_usd', monto_gyd: 29000, usd: 100 },
    { servicio: 'cuban_card', monto_gyd: 5000, usd: null },
  ];
  const s = (deposito: number) =>
    correrDecisor({
      ctx: {
        servicio_resuelto: {
          version: 2, en_curso: 'mexico', servicio: 'mexico', accion: 'ninguna', permitido: true, motivo: 'sin_cambio',
          mensaje: 'x', operaciones: [], adicionales: [], evidencia: { declarado: null, deposito },
          reparto_planeado: { partes, total_gyd: 73000, deposito_gyd: deposito, diferencia_gyd: deposito - 73000, coincide: false },
        },
      },
    });

  it('un deposito corto dice que partes cubre en orden y cuales quedan pendientes', () => {
    const n = nota(s(68000), 'DEPOSITO DISTINTO DE LO ACORDADO') as string;
    expect(n).toMatch(/cubre.*mexico 39,000.*efectivo_usd 29,000/i);
    expect(n).toMatch(/pendiente.*cuban_card 5,000/i);
    expect(n).toMatch(/68,000/);
  });

  it('no dicta la accion: ni pregunta, ni ordena herramientas, ni prohibe', () => {
    const n = nota(s(68000), 'DEPOSITO DISTINTO DE LO ACORDADO') as string;
    expect(n).not.toMatch(/PREGUNTA|PROHIBIDO|llama |sin decidirlo/);
  });

  it('un deposito de mas dice cuanto sobra sobre el total acordado', () => {
    const n = nota(s(80000), 'DEPOSITO DISTINTO DE LO ACORDADO') as string;
    expect(n).toMatch(/sobran? 7,000/i);
  });
});

describe('291 follow-up: recipients are counted across ALL open operations of the send, per operation', () => {
  const op = (servicio: string, extra: Record<string, unknown> = {}) => ({
    id: 'op-' + servicio, servicio, tipo: servicio === 'mexico' || servicio === 'efectivo_usd' ? 'remesa' : servicio,
    rail: servicio, status: 'awaiting_deposit', deposito: 0, tiene_deposito: false, vacia: true,
    tarjeta: false, zelle: false, efectivo: false, celular: false, ...extra,
  });
  const mx = (nombre: string, monto: number) => ({
    t: 'mexico_cuenta', cuenta: null, nombre, tarjeta: null, celular: null, posicion: null, monto, moneda: 'USD',
  });
  const envio = (benef: unknown[]) =>
    correrDecisor({
      ctx: {
        beneficiarios_registrados: benef,
        servicio_resuelto: {
          version: 2, en_curso: 'mexico', servicio: 'mexico', accion: 'ninguna', permitido: true, motivo: 'sin_cambio',
          mensaje: null, operaciones: [op('mexico', { vacia: false }), op('efectivo_usd'), op('recarga', { celular: true })],
          adicionales: [], evidencia: { declarado: null, deposito: 55000 },
        },
      },
      snapshot: { texto_completo: 'ya deposite', celular: '55599180' },
    });

  it('two Mexico recipients of the same send: no "no beneficiary registered" note', () => {
    const s = envio([mx('Ana Perez', 50), mx('Luis Gomez', 50)]);
    expect(nota(s, 'TODAVIA NO HAY BENEFICIARIO REGISTRADO')).toBeUndefined();
  });

  it('gives the model the count and the names per operation', () => {
    const n = nota(envio([mx('Ana Perez', 50), mx('Luis Gomez', 50)]), 'DESTINATARIOS REGISTRADOS POR OPERACION') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/mexico: 2 destinatarios \(Ana Perez 50 USD, Luis Gomez 50 USD\)/);
    expect(n).toMatch(/efectivo_usd: ninguno/);
    expect(n).toMatch(/recarga: 1/);
  });

  it('a Mexico recipient without a name is not complete: the old note stays', () => {
    const s = envio([{ ...mx('', 50) }]);
    expect(nota(s, 'TODAVIA NO HAY BENEFICIARIO REGISTRADO')).toBeDefined();
  });
});

describe('293: PARTES ACORDADAS - cada parte con su monto acordado, lo que cubre el deposito y lo que falta (hechos, sin decidir)', () => {
  const op = (servicio: string, acordado: number | null, dinero = 0, extra: Record<string, unknown> = {}) => ({
    id: `op-${servicio}`,
    servicio,
    tipo: servicio === 'mexico' ? 'mexico' : servicio === 'recarga' ? 'recarga' : 'remesa',
    status: 'collecting_information',
    deposito: dinero,
    dinero_gyd: dinero,
    tiene_deposito: dinero > 0,
    monto_acordado_gyd: acordado,
    vacia: dinero === 0,
    grupo: null,
    ...extra,
  });
  const R = (operaciones: unknown[], extra: Record<string, unknown> = {}) => ({
    version: 2,
    en_curso: null,
    servicio: null,
    accion: 'ninguna',
    permitido: true,
    motivo: 'sin_cambio',
    mensaje: 'x',
    operaciones,
    adicionales: [],
    evidencia: { declarado: null, deposito: 0 },
    reparto_planeado: null,
    ...extra,
  });
  const P = 'PARTES ACORDADAS';
  const tres = (dineroMexico: number) => [
    op('mexico', 26000, dineroMexico),
    op('efectivo_usd', 29000),
    op('recarga', 6200),
  ];

  it('con un deposito de 55,000 cubre las dos primeras partes enteras y dice lo que falta de la recarga', () => {
    const n = nota(correrDecisor({ ctx: { servicio_resuelto: R(tres(55000)) } }), P) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/mexico 26,000/);
    expect(n).toMatch(/efectivo_usd 29,000/);
    expect(n).toMatch(/recarga 6,200/);
    expect(n).toMatch(/61,200/);
    expect(n).toMatch(/55,000/);
    expect(n).toMatch(/cubre completas: mexico 26,000 \+ efectivo_usd 29,000/);
    expect(n).toMatch(/No cubierto: recarga 6,200/);
    expect(n).toMatch(/faltan 6,200 GYD/);
    expect(n).not.toMatch(/PREGUNTA|PROHIBIDO/); // facts only
  });

  it('nunca cubre una parte que excede el deposito: salta a la siguiente que cabe', () => {
    const ops = [op('mexico', 26000, 33000), op('efectivo_usd', 29000), op('recarga', 6200)];
    const n = nota(correrDecisor({ ctx: { servicio_resuelto: R(ops) } }), P) as string;
    expect(n).toMatch(/cubre completas: mexico 26,000 \+ recarga 6,200/);
    expect(n).toMatch(/No cubierto: efectivo_usd 29,000/);
    expect(n).toMatch(/faltan 28,200 GYD/);
  });

  it('sin deposito lista las partes y lo dice', () => {
    const n = nota(correrDecisor({ ctx: { servicio_resuelto: R(tres(0)) } }), P) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/mexico 26,000 \+ efectivo_usd 29,000 \+ recarga 6,200/);
    expect(n).toMatch(/Todavia no hay deposito/);
  });

  it('una sola parte, o un reparto planeado, no generan la nota', () => {
    expect(nota(correrDecisor({ ctx: { servicio_resuelto: R([op('mexico', 26000)]) } }), P)).toBeUndefined();
    const plan = { partes: [{ servicio: 'mexico', monto_gyd: 26000, usd: 100 }, { servicio: 'efectivo_usd', monto_gyd: 29000, usd: 100 }], total_gyd: 55000, deposito_gyd: null, diferencia_gyd: null, coincide: false };
    expect(nota(correrDecisor({ ctx: { servicio_resuelto: R(tres(0), { reparto_planeado: plan }) } }), P)).toBeUndefined();
  });
});

describe('invitacion al grupo de WhatsApp', () => {
  const LINK = 'https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81';

  it('la anade en el primer mensaje del cliente', () => {
    const out = turno('hola', { ctx: { mensajes_cliente: 1 } });
    expect(out.mensaje).toContain('CLIENTE NUEVO');
    expect(out.mensaje).toContain('*Remesas Ya*');
    expect(out.mensaje).toContain(LINK);
    expect(out.mensaje).toMatch(/UNA sola vez/);
  });

  it('no la repite cuando el cliente ya habia escrito', () => {
    const out = turno('hola', { ctx: { mensajes_cliente: 3 } });
    expect(out.mensaje).not.toContain('CLIENTE NUEVO');
    expect(out.mensaje).not.toContain(LINK);
  });

  it('no se le manda a un admin', () => {
    const out = turno('hola', { ctx: { mensajes_cliente: 1, es_admin: true } });
    expect(out.ruta).toBe('silencio');
    expect(out.mensaje ?? '').not.toContain(LINK);
  });
});

describe('minimos de deposito por servicio', () => {
  it('Clasica y Tropical llevan su propio minimo; Zelle conserva el suyo', () => {
    const out = turno('cual es el minimo para clasica?', {
      ctx: {
        minimos: {
          minimo_gyd_cup: '5000',
          minimo_usd_clasica: '20',
          minimo_usd_tropical: '20',
          minimo_usd_zelle: '50',
          minimo_usd_efectivo: '100',
        },
      },
    });
    expect(out.mensaje).toContain('tarjeta Clasica 20 USD');
    expect(out.mensaje).toContain('tarjeta Tropical 20 USD');
    expect(out.mensaje).toContain('Zelle 50 USD');
    expect(out.mensaje).toContain('efectivo en USD 100 USD');
  });
});


describe('verificar un deposito por TransID escrito (admin)', () => {
  it('un numero suelto de 14 digitos es un TransID', () => {
    const out = turno('10404033303182', { ctx: { es_admin: true } });
    expect(out.ruta).toBe('comando');
    expect((out as unknown as { comando?: string }).comando).toBe('verificar_transid');
    expect((out as unknown as { objetivo?: string }).objetivo).toBe('10404033303182');
  });

  it('"verifica 10404033303182" tambien', () => {
    const out = turno('verifica 10404033303182', { ctx: { es_admin: true } });
    expect((out as unknown as { comando?: string }).comando).toBe('verificar_transid');
  });

  it('a un cliente no le convierte el numero en comando', () => {
    const out = turno('10404033303182', { ctx: { es_admin: false } });
    expect((out as unknown as { comando?: string }).comando).not.toBe('verificar_transid');
  });
});

// Owner 2026-10-25 (Osmany's list): name the service, never ask for a card on a
// recarga, and promise no time — "una vez hecho su servicio, se le notifica por aca".
describe('nombre del servicio, recarga sin tarjeta y promesa neutra', () => {
  const ABIERTO = '2026-10-21T15:00:00Z'; // 11:00 Guyana
  const CERRADO = '2026-10-21T07:00:00Z'; // 03:00 Guyana

  function a(hora: string, extra: Entradas = {}) {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(hora));
    try {
      return correrDecisor(extra);
    } finally {
      vi.useRealTimers();
    }
  }

  afterEach(() => {
    vi.useRealTimers();
  });

  it('con Zelle resuelto, ordena nombrar el servicio y no decir solo "USD"', () => {
    const s = a(ABIERTO, { ctx: { riel_operacion: 'zelle' } });
    const n = nota(s, 'NOMBRA EL SERVICIO');
    expect(n).toBeDefined();
    expect(n).toContain('Zelle');
    expect(n).toMatch(/PROHIBIDO decir solo "USD"/);
  });

  it('una recarga no pide tarjeta: solo el numero cubano', () => {
    const s = a(ABIERTO, { snapshot: { texto_completo: 'recargame 500 a este numero' } });
    const n = nota(s, 'EL CLIENTE PIDE UNA RECARGA');
    expect(n).toBeDefined();
    expect(n).toMatch(/PROHIBIDO pedir tarjeta/);
    expect(n).toContain('NUMERO');
  });

  it('fuera de horario ya no promete "en cuanto abramos"', () => {
    const n = nota(a(CERRADO), 'FUERA DE HORARIO');
    expect(n).toBeDefined();
    expect(n).toContain('una vez hecho su servicio, se le notifica por aca');
    expect(n).not.toMatch(/Di que se hace en cuanto abramos/);
  });

  it('proximo a cerrar ya no promete el dia siguiente a primera hora', () => {
    const n = nota(a(ABIERTO, { ctx: { por_cerrar: true } }), 'PROXIMO A CERRAR');
    expect(n).toBeDefined();
    expect(n).toContain('una vez hecho su servicio, se le notifica por aca');
    expect(n).not.toMatch(/queda para el dia siguiente/);
  });
});
