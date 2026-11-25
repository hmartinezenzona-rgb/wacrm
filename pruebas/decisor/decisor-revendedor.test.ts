// Reseller deposit route (398, design Decision 20).
//
// A reseller deposit creates NO operation: the wrapper records a pending claim and the
// MMG cross verifies it in the background. The bot must answer with fixed text per cross
// verdict, on the reseller's own chat, without reaching the agent and without asking for a
// beneficiary (the reseller is not sending money to anyone). If this text were left to the
// model, the customer script would kick in and ask for a beneficiary that does not exist.
import { describe, expect, it } from 'vitest';

import { correrDecisor, type Entradas } from './correr';

const TEXTO_VERIFICADO = 'Depósito verificado. Ya lo sumé a tu total.';
const TEXTO_VERIFICADO_MONTO =
  'Depósito verificado por 26.000 GYD. Ya lo sumé a tu total.';
const TEXTO_NO_ENCONTRADO =
  'Todavía no aparece en el banco. En cuanto lo vea te lo confirmo.';
const TEXTO_YA_REGISTRADO = 'Ese depósito ya lo tenía registrado.';
const TEXTO_YA_REGISTRADO_MONTO =
  'Ese depósito ya lo tenía registrado por 26.000 GYD.';
const TEXTO_REVISION = 'Reviso ese comprobante y te confirmo.';

const COMPROBANTE = {
  estado: 'LEGIBLE',
  monto: 26000,
  moneda: 'GYD',
  referencia: '20404215436140',
  alertas: [],
};

interface SalidaComando {
  ruta: string;
  comando?: string;
  objetivo?: string;
  valor?: unknown;
  telefono_e164?: string;
  mensaje?: string;
}

/**
 * A reseller turn with a readable receipt. `ctx` and `snapshot` overrides let each test
 * drive one variable; `mmg` is the `Cruzar deposito con MMG` output.
 */
function turnoRevendedor(
  mmg: Entradas['mmg'] = {},
  extra: Entradas = {}
): SalidaComando {
  return correrDecisor({
    ...extra,
    ctx: { es_revendedor: true, ...(extra.ctx ?? {}) },
    snapshot: {
      texto_completo: 'ahi va el comprobante',
      comprobante: COMPROBANTE,
      ...(extra.snapshot ?? {}),
    },
    mmg,
  }) as unknown as SalidaComando;
}

describe('revendedor: el veredicto del cruce decide el texto, sin llegar al agente', () => {
  it.each([
    ['verificado exacto', { resultado: 'verificado', trans_id: '20404215436140' }],
    ['verificado aproximado', { resultado: 'verificado', trans_id: '20404215436141', metodo: 'aproximado' }],
    ['verificado incompleto', { resultado: 'verificado_incompleto' }],
    ['verificado de mas', { resultado: 'verificado_de_mas' }],
  ])('%s: confirma que se sumo al total con el monto del deposito', (_caso, mmg) => {
    const out = turnoRevendedor(mmg);
    expect(out.ruta).toBe('comando');
    expect(out.comando).toBe('verificar');
    expect(out.objetivo).toBe(TEXTO_VERIFICADO_MONTO);
    expect(out.telefono_e164).toBe('+5920000000');
  });

  it('el monto verificado del cruce manda sobre el leido del comprobante', () => {
    const out = turnoRevendedor({
      resultado: 'verificado',
      total_verificado: 45000,
    });
    expect(out.objetivo).toBe(
      'Depósito verificado por 45.000 GYD. Ya lo sumé a tu total.'
    );
  });

  it.each([
    ['sin correo todavia', { resultado: 'sin_correo' }],
    ['sin referencia', { resultado: 'sin_referencia' }],
  ])('%s: dice que aun no aparece en el banco', (_caso, mmg) => {
    const out = turnoRevendedor(mmg);
    expect(out.ruta).toBe('comando');
    expect(out.comando).toBe('verificar');
    expect(out.objetivo).toBe(TEXTO_NO_ENCONTRADO);
  });

  it('ya reclamado: dice que ya lo tenia registrado y por cuanto', () => {
    const out = turnoRevendedor({ resultado: 'ya_reclamado' });
    expect(out.ruta).toBe('comando');
    expect(out.comando).toBe('verificar');
    expect(out.objetivo).toBe(TEXTO_YA_REGISTRADO_MONTO);
  });

  it.each([
    ['monto no coincide', { resultado: 'monto_no_coincide' }],
    ['deposito antiguo', { resultado: 'deposito_antiguo' }],
    ['deposito anulado', { resultado: 'deposito_anulado' }],
    ['no aplica', { resultado: 'no_aplica' }],
    ['sin cruce', {}],
  ])('%s: lo revisa una persona', (_caso, mmg) => {
    const out = turnoRevendedor(mmg);
    expect(out.ruta).toBe('comando');
    expect(out.comando).toBe('verificar');
    expect(out.objetivo).toBe(TEXTO_REVISION);
  });

  it('un comprobante repetido se responde como ya registrado, sin consultar el cruce', () => {
    const out = turnoRevendedor({}, {
      snapshot: { comprobante_duplicado: true },
    });
    expect(out.ruta).toBe('comando');
    expect(out.objetivo).toBe(TEXTO_YA_REGISTRADO_MONTO);
  });
});

describe('revendedor: monto del deposito (formato espanol y repliegue seguro)', () => {
  it('una rafaga sin total verificado usa la suma leida de los comprobantes', () => {
    const out = turnoRevendedor(
      { resultado: 'ya_reclamado' },
      { snapshot: { comprobantes_total: 45000 } }
    );
    expect(out.objetivo).toBe(
      'Ese depósito ya lo tenía registrado por 45.000 GYD.'
    );
  });

  it('formatea los miles con punto y sin decimales cuando el monto es entero', () => {
    const out = turnoRevendedor({
      resultado: 'verificado',
      total_verificado: 1234567,
    });
    expect(out.objetivo).toBe(
      'Depósito verificado por 1.234.567 GYD. Ya lo sumé a tu total.'
    );
  });

  it('conserva los decimales cuando el monto no es entero', () => {
    const out = turnoRevendedor({
      resultado: 'verificado',
      total_verificado: 1234.5,
    });
    expect(out.objetivo).toBe(
      'Depósito verificado por 1.234,5 GYD. Ya lo sumé a tu total.'
    );
  });

  it('sin monto disponible usa el texto sin monto y no imprime basura', () => {
    const out = turnoRevendedor(
      { resultado: 'verificado', total_verificado: null },
      { snapshot: { comprobante: { ...COMPROBANTE, monto: undefined } } }
    );
    expect(out.objetivo).toBe(TEXTO_VERIFICADO);
    expect(out.objetivo ?? '').not.toMatch(/undefined|NaN|null/i);
  });

  it('con un monto no numerico usa el texto sin monto', () => {
    const out = turnoRevendedor(
      { resultado: 'ya_reclamado' },
      { snapshot: { comprobante: { ...COMPROBANTE, monto: 'no legible' } } }
    );
    expect(out.objetivo).toBe(TEXTO_YA_REGISTRADO);
    expect(out.objetivo ?? '').not.toMatch(/undefined|NaN|null/i);
  });

  it('un monto cero no se imprime como si fuera un deposito', () => {
    const out = turnoRevendedor(
      { resultado: 'verificado', total_verificado: 0 },
      { snapshot: { comprobante: { ...COMPROBANTE, monto: 0 } } }
    );
    expect(out.objetivo).toBe(TEXTO_VERIFICADO);
  });
});

describe('revendedor: nunca llega al agente ni pide beneficiario', () => {
  it.each([
    ['verificado', { resultado: 'verificado' }],
    ['no encontrado', { resultado: 'sin_correo' }],
    ['ya reclamado', { resultado: 'ya_reclamado' }],
    ['revision', { resultado: 'monto_no_coincide' }],
  ])('%s: respuesta fija, sin mensaje de agente ni pedido de datos', (_caso, mmg) => {
    const out = turnoRevendedor(mmg);
    expect(out.ruta).not.toBe('agente');
    expect(out.mensaje).toBeUndefined();
    expect(out.objetivo ?? '').not.toMatch(/beneficiar|quien recibe|tarjeta|celular/i);
    expect(out.objetivo ?? '').not.toMatch(/TransID/i);
  });
});

describe('revendedor: las guardas y el admin siguen mandando', () => {
  it.each([
    ['bot pausado', { bot_pausado: true }, 'bot pausado a mano en esta conversacion'],
    ['chat oculto', { oculta: true }, 'chat oculto por el operador'],
    ['chat asignado', { asignado: true }, 'chat asignado a humano'],
    ['humano reciente', { humano_reciente: true }, 'un humano del equipo acaba de escribir'],
  ])('%s: silencio, aunque sea un deposito de revendedor', (_caso, ctx, motivo) => {
    const out = turnoRevendedor({ resultado: 'verificado' }, { ctx }) as SalidaComando & {
      motivo?: string;
    };
    expect(out.ruta).toBe('silencio');
    expect(out.motivo).toBe(motivo);
  });

  it('un admin tiene precedencia: recibe el veredicto de admin, no el de revendedor', () => {
    const out = turnoRevendedor(
      { resultado: 'verificado' },
      { ctx: { es_admin: true } }
    );
    expect(out.ruta).toBe('comando');
    expect(out.comando).toBe('verificar');
    expect(out.objetivo).toMatch(/^VERIFICADO: casa con el correo de MMG/);
    expect(out.objetivo).not.toBe(TEXTO_VERIFICADO);
  });
});

describe('revendedor: no cambia a los demas clientes', () => {
  it('un cliente no revendedor con comprobante verificado sigue yendo al agente', () => {
    const out = correrDecisor({
      ctx: { es_revendedor: false },
      snapshot: { texto_completo: 'ahi va', comprobante: COMPROBANTE },
      mmg: { resultado: 'verificado' },
    }) as unknown as SalidaComando;
    expect(out.ruta).toBe('agente');
    expect(out.comando).toBeUndefined();
    expect(out.mensaje).toMatch(/Comprobante leido y YA REGISTRADO/);
  });

  it('un revendedor sin comprobante en este turno sigue la conversacion normal', () => {
    const out = correrDecisor({
      ctx: { es_revendedor: true },
      snapshot: { texto_completo: 'hola, cuanto es el minimo?' },
    }) as unknown as SalidaComando;
    expect(out.ruta).toBe('agente');
    expect(out.comando).toBeUndefined();
  });

  it('sin el campo es_revendedor no se activa (contexto viejo)', () => {
    const out = correrDecisor({
      snapshot: { texto_completo: 'ahi va', comprobante: COMPROBANTE },
      mmg: { resultado: 'verificado' },
    }) as unknown as SalidaComando;
    expect(out.ruta).toBe('agente');
    expect(out.comando).toBeUndefined();
  });
});
