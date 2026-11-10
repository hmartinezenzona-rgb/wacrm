// Tests for the LIVE production Decisor (`./decisor.jscode`), a different lineage from the staging
// copy tested in `../decisor-notas.test.ts`. The baseline block locks what production already does
// and the owner tested on 2026-10-27; it must keep passing through every later change.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  correrDecisorProduccion as correr,
  DECISOR_PRODUCCION_MD5_ESPERADO,
  nota,
  ORIGEN_PRODUCCION,
  type Entradas,
} from './correr';

describe('la copia de produccion no puede derivar en silencio', () => {
  it('mantiene la huella del nodo vendorizado', () => {
    const md5 = createHash('md5')
      .update(readFileSync(ORIGEN_PRODUCCION))
      .digest('hex');
    expect(md5).toBe(DECISOR_PRODUCCION_MD5_ESPERADO);
  });
});

describe('baseline de produccion: lo que ya funciona no se toca', () => {
  it('g82: reparto con Zelle manda repartir_envio ademas de registrar_reparto_multiple', () => {
    const s = correr({
      ctx: {
        beneficiarios_registrados: [
          {
            t: 'multiple_distribution',
            posicion: 1,
            tarjeta: '9224069992922522',
            celular: '53821202',
            monto: 5000,
          },
          {
            t: 'multiple_distribution',
            posicion: 2,
            tarjeta: '9224069992922523',
            celular: '53821203',
            monto: 5000,
          },
        ],
      },
      snapshot: {
        texto_completo: 'ok',
        datos_zelle: true,
        zelle_correo: 'a@b.com',
      },
    });
    const n = nota(s, 'REPARTO EN CURSO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/registrar_reparto_multiple/);
    expect(n).toMatch(/ADEMAS este envio lleva ZELLE/);
    expect(n).toMatch(/repartir_envio/);
  });

  it('g82: sin Zelle el reparto no menciona repartir_envio', () => {
    const s = correr({
      ctx: {
        beneficiarios_registrados: [
          {
            t: 'multiple_distribution',
            posicion: 1,
            tarjeta: '9224069992922522',
            celular: '53821202',
            monto: 5000,
          },
          {
            t: 'multiple_distribution',
            posicion: 2,
            tarjeta: '9224069992922523',
            celular: '53821203',
            monto: 5000,
          },
        ],
      },
      snapshot: { texto_completo: 'ok' },
    });
    const n = nota(s, 'REPARTO EN CURSO') as string;
    expect(n).toBeDefined();
    expect(n).not.toMatch(/repartir_envio/);
  });

  it('Zelle: nota DATOS DE ZELLE DETECTADOS con la cuenta literal y la orden de registrar', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: 'Maria Lopez maria@correo.com',
        datos_zelle: true,
        zelle_nombre: 'Maria Lopez',
        zelle_correo: 'maria@correo.com',
      },
    });
    const n = nota(s, 'DATOS DE ZELLE DETECTADOS') as string;
    expect(n).toBeDefined();
    expect(n).toContain('maria@correo.com');
    expect(n).toMatch(/PROHIBIDO pedirle tarjeta/);
    expect(n).toMatch(/registrar_beneficiario_zelle/);
  });

  it('tarjeta y celular sin registrar: manda llamar gestionar_beneficiario', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      ctx: { beneficiarios_registrados: [] },
      snapshot: {
        texto_completo: 'ok',
        tarjeta: '9224069992922522',
        celular: '53821202',
      },
    });
    const n = nota(
      s,
      'TARJETA Y CELULAR DETECTADOS PERO NO REGISTRADOS'
    ) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/Llama gestionar_beneficiario/);
  });

  it('beneficiario ya registrado: confirma tarjeta y celular completos', () => {
    const s = correr({
      ctx: {
        beneficiarios_registrados: [
          { t: 'cuban_card', tarjeta: '9224069992922522', celular: '53821202' },
        ],
      },
      snapshot: {
        texto_completo: 'mi tarjeta y mi celular van aqui',
        tarjeta: '9224069992922522',
        celular: '53821202',
      },
    });
    const n = nota(s, 'Beneficiario YA REGISTRADO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/OBLIGATORIO/);
    expect(n).toMatch(/NO llames gestionar_beneficiario/);
  });

  it('sin ausencia ni historial no sale ninguna nota de ausencia ni de seguimiento', () => {
    const s = correr({ snapshot: { texto_completo: 'hola' } });
    expect(nota(s, 'AUSENCIA')).toBeUndefined();
    expect(nota(s, 'TURNO DE SEGUIMIENTO')).toBeUndefined();
  });
});

describe('aviso de ausencia temporal (away mode)', () => {
  const AUSENCIA = {
    motivo: 'en una reunion',
    hasta: '2026-10-21T19:00:00Z',
    hasta_texto: 'a las 3:00 pm',
    por: 'dueno',
  };
  // The node reads the process clock in America/Guyana (UTC-4). Wednesday 2026-10-21.
  const ABIERTO = '2026-10-21T15:00:00Z'; // 11:00 Guyana
  const FUERA_DE_HORA = '2026-10-21T07:00:00Z'; // 03:00 Guyana
  const DOMINGO = '2026-10-25T15:00:00Z'; // Sunday 11:00 Guyana

  function a(hora: string, ce: unknown, extra: Entradas = {}) {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(hora));
    try {
      return correr({
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

  it('abierto, primer contacto del dia: avisa con motivo y hora de regreso y sigue atendiendo', () => {
    const n = nota(
      a(
        ABIERTO,
        { ausencia: AUSENCIA },
        { historial: { primer_del_dia: true } }
      ),
      'AUSENCIA TEMPORAL'
    ) as string;
    expect(n).toBeDefined();
    expect(n).toContain('en una reunion');
    expect(n).toContain('a las 3:00 pm');
    expect(n).toMatch(/los encargados no estan disponibles/);
    expect(n).toMatch(/SIGUE ATENDIENDO NORMAL/);
    expect(n).toMatch(/PROHIBIDO decir "en breve" o "enseguida"/);
  });

  it('abierto, ya presentado hoy: solo queda la guarda de no repetir', () => {
    const s = a(
      ABIERTO,
      { ausencia: AUSENCIA },
      { historial: { primer_del_dia: false } }
    );
    expect(nota(s, 'AUSENCIA TEMPORAL')).toBeUndefined();
    const n = nota(s, 'AUSENCIA YA AVISADA HOY') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/NO repitas/);
    expect(n).not.toContain('en una reunion');
  });

  it('fuera de horario no avisa de la ausencia', () => {
    const s = a(
      FUERA_DE_HORA,
      { ausencia: AUSENCIA },
      { historial: { primer_del_dia: true } }
    );
    expect(nota(s, 'AUSENCIA')).toBeUndefined();
    expect(nota(s, 'FUERA DE HORARIO')).toBeDefined();
  });

  it('domingo no avisa de la ausencia', () => {
    const s = a(
      DOMINGO,
      { ausencia: AUSENCIA },
      { historial: { primer_del_dia: true } }
    );
    expect(nota(s, 'AUSENCIA')).toBeUndefined();
  });

  it('dia cerrado no avisa de la ausencia', () => {
    const s = a(
      ABIERTO,
      { hoy_motivo: 'feriado', ausencia: AUSENCIA },
      { historial: { primer_del_dia: true } }
    );
    expect(nota(s, 'AUSENCIA')).toBeUndefined();
  });

  it('ausencia mal formada o incompleta se ignora', () => {
    for (const ausencia of [
      null,
      'texto',
      {},
      { motivo: 'x' },
      { hasta_texto: 'a las 3' },
    ]) {
      const s = a(
        ABIERTO,
        { ausencia },
        { historial: { primer_del_dia: true } }
      );
      expect(nota(s, 'AUSENCIA'), JSON.stringify(ausencia)).toBeUndefined();
    }
  });

  it('sin ausencia no hay nota', () => {
    const s = a(ABIERTO, {}, { historial: { primer_del_dia: true } });
    expect(nota(s, 'AUSENCIA')).toBeUndefined();
  });
});

describe('turno de seguimiento: respuesta breve cuando el cliente ya tiene la cotizacion', () => {
  // Production `Contexto conversacion` has no `mensajes_cliente`. The signal available to the live
  // Decisor is `Ultima cotizacion.ultima_cotizacion`: the last agent message of the last 6 hours
  // that carries a quoted amount (*N GYD|MXN|USD*), i.e. the customer already received a quote.
  const COTIZADO = {
    ultima_cotizacion: 'Por *8,000 GYD* llegan *24,000 CUP* a Cuba.',
  };
  const PREFIJO = 'TURNO DE SEGUIMIENTO (BREVEDAD)';

  it('con cotizacion ya enviada y un mensaje de seguimiento, avisa de ser breve', () => {
    const s = correr({
      cotizacion: COTIZADO,
      snapshot: { texto_completo: 'la tarjeta es 9224069992922522' },
    });
    const n = nota(s, PREFIJO) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/NO re-listes la cotizacion/);
    expect(n).toMatch(/1-2 frases/);
  });

  it('sin cotizacion previa (primer mensaje o solo saludo) no se activa', () => {
    for (const cotizacion of [
      {},
      { ultima_cotizacion: null },
      { ultima_cotizacion: '' },
    ]) {
      const s = correr({
        cotizacion,
        snapshot: { texto_completo: 'quiero enviar 8000' },
      });
      expect(nota(s, PREFIJO), JSON.stringify(cotizacion)).toBeUndefined();
    }
  });

  it('si el cliente pide una cotizacion nueva no se activa', () => {
    for (const texto of [
      'cuanto le llega si deposito 10 mil',
      'cuánto llegan con 20000',
      'cuanto tengo que depositar para que lleguen 30000',
      'cuánto debo enviar para 50 usd',
    ]) {
      const s = correr({
        cotizacion: COTIZADO,
        snapshot: { texto_completo: texto },
      });
      expect(nota(s, PREFIJO), texto).toBeUndefined();
    }
  });
});

describe('beneficiario ya confirmado: no se repiten tarjeta ni celular', () => {
  const registrados = {
    beneficiarios_registrados: [
      { t: 'cuban_card', tarjeta: '9224069992922522', celular: '53821202' },
    ],
  };
  const PREFIJO = 'Beneficiario YA REGISTRADO';

  it('si el cliente solo acusa recibo, responde en una frase corta sin repetir los datos', () => {
    for (const texto of ['ok', 'Perfecto', 'gracias!', 'listo']) {
      const s = correr({
        ctx: registrados,
        snapshot: {
          texto_completo: texto,
          tarjeta: '9224069992922522',
          celular: '53821202',
        },
      });
      const n = nota(s, PREFIJO) as string;
      expect(n, texto).toBeDefined();
      expect(n, texto).toMatch(/solo acusa recibo/);
      expect(n, texto).toMatch(/UNA frase corta/);
      expect(n, texto).not.toMatch(/OBLIGATORIO/);
    }
  });

  it('si uno de los datos se dio antes, no repite tarjeta ni celular', () => {
    const s = correr({
      ctx: registrados,
      snapshot: { texto_completo: 'Listo ahi le deposite' },
      beneficiario: {
        tarjeta_final: '9224069992922522',
        celular_final: '53821202',
      },
    });
    const n = nota(s, PREFIJO) as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/NO repitas tarjeta ni celular/);
    expect(n).not.toMatch(/OBLIGATORIO/);
  });

  it('con datos nuevos en este lote sigue exigiendo la confirmacion completa', () => {
    const s = correr({
      ctx: registrados,
      snapshot: {
        texto_completo: 'la tarjeta y el celular',
        tarjeta: '9224069992922522',
        celular: '53821202',
      },
    });
    const n = nota(s, PREFIJO) as string;
    expect(n).toMatch(/OBLIGATORIO/);
    expect(n).not.toMatch(/NO repitas tarjeta ni celular/);
  });

  // The card came in an earlier message and the phone arrives now: the pair is complete for the
  // FIRST time, so it has never been confirmed and the full confirmation is still owed.
  it('si la tarjeta vino antes y el celular llega ahora, confirma completo', () => {
    const s = correr({
      ctx: registrados,
      snapshot: {
        texto_completo: 'el celular es 53821202',
        celular: '53821202',
      },
      beneficiario: {
        tarjeta_final: '9224069992922522',
        celular_final: '53821202',
      },
    });
    const n = nota(s, PREFIJO) as string;
    expect(n).toMatch(/OBLIGATORIO/);
    expect(n).not.toMatch(/NO repitas tarjeta ni celular/);
  });
});

describe('fase 1 formato: ninguna nota dicta un plazo que el negocio no controla', () => {
  // Wednesday 2026-10-21 (Guyana is UTC-4).
  const ABIERTO = '2026-10-21T15:00:00Z'; // 11:00
  const CERRADO = '2026-10-21T07:00:00Z'; // 03:00
  const PROHIBIDAS =
    /enseguida|en breve|a primera hora|en cuanto abramos|en cuanto ellos regresen/i;

  function en(hora: string, e: Entradas = {}) {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(hora));
    try {
      return correr(e);
    } finally {
      vi.useRealTimers();
    }
  }

  // A prohibition ("PROHIBIDO decir ... .") may name the banned words; a dictated phrase may not.
  const sinProhibiciones = (n: string) => n.replace(/PROHIBIDO[^.]*\./g, '');
  const dictadas = (notas: string[]) =>
    notas.filter((n) => PROHIBIDAS.test(sinProhibiciones(n)));

  const comp = { moneda: 'GYD', estado: 'OK', alertas: [] };
  const conComp = (mmg: Record<string, unknown> = {}, ctx = {}) => ({
    snapshot: { texto_completo: 'ok', comprobante: comp },
    mmg,
    ctx,
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('cerrado: queda registrado y se procesa a partir de la hora de apertura', () => {
    const n = nota(en(CERRADO), 'FUERA DE HORARIO: ahora mismo') as string;
    expect(n).toContain(
      'queda registrado y se procesa a partir de las 8:00 am (hora de Guyana)'
    );
    expect(dictadas([n])).toEqual([]);
  });

  it('cerrado con proximo cierre: nombra el dia habil sin prometer apertura inmediata', () => {
    const s = en(CERRADO, {
      ctx: {
        cierre_especial: {
          proximo_habil: 'el martes',
          proximo_cierre: 'el lunes es feriado',
        },
      },
    });
    const n = nota(s, 'FUERA DE HORARIO: ahora mismo') as string;
    expect(n).toContain(
      'queda registrado y se procesa el martes a partir de las 8:00 am (hora de Guyana)'
    );
    expect(dictadas([n])).toEqual([]);
  });

  it('dia cerrado entero: lo pendiente queda registrado y se procesa a partir de la apertura', () => {
    const s = en(ABIERTO, {
      ctx: {
        cierre_especial: {
          hoy_motivo: 'por feriado',
          proximo_habil: 'el jueves',
        },
      },
    });
    const n = nota(s, 'FUERA DE HORARIO: HOY NO SE TRABAJA') as string;
    expect(n).toContain(
      'queda registrado y se procesa el jueves a partir de las 8:00 am (hora de Guyana)'
    );
    expect(dictadas([n])).toEqual([]);
  });

  it('proximo a cerrar: queda registrado y se procesa a partir de la apertura, sin "primera hora"', () => {
    const n = nota(
      en(ABIERTO, { ctx: { por_cerrar: true } }),
      'PROXIMO A CERRAR'
    ) as string;
    expect(n).toContain(
      'queda registrado y se procesa a partir de las 8:00 am (hora de Guyana)'
    );
    expect(dictadas([n])).toEqual([]);
  });

  it('ausencia temporal: no promete "en cuanto ellos regresen" y conserva la prohibicion', () => {
    const n = nota(
      en(ABIERTO, {
        ctx: {
          cierre_especial: {
            ausencia: {
              motivo: 'en una reunion',
              hasta: '2026-10-21T19:00:00Z',
              hasta_texto: 'a las 3:00 pm',
              por: 'dueno',
            },
          },
        },
        historial: { primer_del_dia: true },
      }),
      'AUSENCIA TEMPORAL'
    ) as string;
    expect(n).toContain(
      'lo suyo queda registrado y se procesa a partir de que regresen'
    );
    expect(n).toMatch(/PROHIBIDO decir "en breve" o "enseguida"/);
    expect(dictadas([n])).toEqual([]);
  });

  it('comprobante sin verificar: una persona lo revisa y le confirma por aqui', () => {
    const n = nota(
      en(ABIERTO, conComp()),
      'Comprobante leido y REGISTRADO'
    ) as string;
    expect(n).toContain('una persona lo revisa y le confirma por aqui');
    expect(dictadas([n])).toEqual([]);
  });

  it('varios comprobantes sin sumar: una persona suma y le confirma por aqui', () => {
    const e = conComp();
    e.snapshot = { ...e.snapshot, comprobantes_n: 2 } as typeof e.snapshot;
    const n = nota(
      en(ABIERTO, e),
      'EL CLIENTE MANDO VARIOS COMPROBANTES'
    ) as string;
    expect(n).toContain('le confirma por aqui');
    expect(dictadas([n])).toEqual([]);
  });

  it('deposito de mas, ya reclamado y antiguo: una persona le confirma por aqui', () => {
    const casos: [Record<string, unknown>, string][] = [
      [
        {
          resultado: 'verificado_de_mas',
          saldo: -500,
          objetivo: 5000,
          depositado: 5500,
        },
        'EL CLIENTE DEPOSITO MAS',
      ],
      [{ resultado: 'ya_reclamado' }, 'ESE DEPOSITO YA SE USO'],
      [{ resultado: 'deposito_antiguo' }, 'EL DEPOSITO ES DEMASIADO ANTIGUO'],
    ];
    for (const [mmg, prefijo] of casos) {
      const n = nota(en(ABIERTO, conComp(mmg)), prefijo) as string;
      expect(n, prefijo).toBeDefined();
      expect(n, prefijo).toContain('una persona');
      expect(n, prefijo).toContain('por aqui');
      expect(dictadas([n]), prefijo).toEqual([]);
    }
  });

  it('comprobante duplicado: ninguna etapa dicta plazo y las revisiones confirman por aqui', () => {
    for (const dup_etapa of [
      'Entregada',
      'Lista para transferir',
      'Incidencia',
      'Por verificar',
      '',
    ]) {
      const s = en(ABIERTO, {
        snapshot: {
          texto_completo: 'ok',
          comprobante: comp,
          comprobante_duplicado: true,
        },
        ctx: { dup_etapa },
      });
      const n = nota(s, 'ESTE COMPROBANTE YA ESTABA REGISTRADO') as string;
      expect(n, dup_etapa).toBeDefined();
      expect(dictadas([n]), dup_etapa).toEqual([]);
      if (dup_etapa !== 'Entregada' && dup_etapa !== 'Lista para transferir') {
        expect(n, dup_etapa).toContain('le confirma por aqui');
      }
    }
  });

  describe('estado real del envio en curso', () => {
    const estado = (etapa: string, ctx: Record<string, unknown> = {}) =>
      nota(
        en(ABIERTO, {
          historial: { etapa_envio_abierto: etapa },
          ctx: { tiene_beneficiario: true, ...ctx },
        }),
        'ESTADO REAL DEL ENVIO EN CURSO'
      ) as string;

    it('lista para transferir: el equipo la esta procesando y le avisan por aqui', () => {
      const n = estado('Lista para transferir');
      expect(n).toContain(
        'el equipo esta procesando la transferencia y le avisamos por aqui cuando este hecha'
      );
      expect(dictadas([n])).toEqual([]);
    });

    it('lista para transferir con el negocio cerrado: se procesa a partir de la apertura', () => {
      const n = nota(
        en(CERRADO, {
          historial: { etapa_envio_abierto: 'Lista para transferir' },
          ctx: { tiene_beneficiario: true },
        }),
        'ESTADO REAL DEL ENVIO EN CURSO'
      ) as string;
      expect(n).not.toContain('el equipo esta procesando');
      expect(n).toMatch(
        /queda registrada y se procesa a partir de las .+ \(hora de Guyana\)/
      );
      expect(n).toContain('le avisamos por aqui cuando este hecha');
      expect(dictadas([n])).toEqual([]);
    });

    it('por verificar e incidencia: una persona lo revisa y le confirma por aqui', () => {
      for (const etapa of ['Por verificar', 'Incidencia']) {
        const n = estado(etapa);
        expect(n, etapa).toContain(
          'una persona lo revisa y le confirma por aqui'
        );
        expect(dictadas([n]), etapa).toEqual([]);
      }
    });

    it('sin destino conocido: sigue sin prometer la transferencia', () => {
      const n = nota(
        en(ABIERTO, {
          historial: { etapa_envio_abierto: 'Lista para transferir' },
        }),
        'ESTADO REAL DEL ENVIO EN CURSO'
      ) as string;
      expect(n).not.toContain('esta procesando la transferencia');
      expect(n).toMatch(/TODAVIA NO SE SABE A QUIEN TRANSFERIRLE/);
      expect(n).toContain('dile que ya quedo verificado.');
      expect(dictadas([n])).toEqual([]);
    });

    it('recarga, visa: la frase se adapta al servicio', () => {
      const r = estado('Lista para transferir', {
        recarga_en_curso: true,
        celular: '53821202',
      });
      expect(r).toContain(
        'el equipo esta procesando la recarga y le avisamos por aqui cuando este hecha'
      );
      expect(dictadas([r])).toEqual([]);
      const v = estado('Lista para transferir', { visa_en_curso: true });
      expect(v).toContain(
        'el equipo sube su aplicacion de extension de visa y le avisamos por aca'
      );
      expect(dictadas([v])).toEqual([]);
    });

    it('combo: una persona llama primero, sin "enseguida"', () => {
      const c = estado('Lista para transferir', {
        combo_en_curso: true,
        combo_completo: true,
      });
      expect(c).toContain(
        'una persona del equipo le llama para elegir los productos'
      );
      expect(dictadas([c])).toEqual([]);
    });

    it('recarga anotada: se hace el dia de la promocion', () => {
      const n = estado('Lista para transferir', {
        recarga_en_curso: true,
        recarga_anotada_para: 'viernes 30',
      });
      expect(n).toContain('la recarga se hace el viernes 30');
      expect(dictadas([n])).toEqual([]);
    });
  });

  it('MLC: lo atiende una persona del equipo, sin "enseguida"', () => {
    const n = nota(
      en(ABIERTO, { ctx: { pide_mlc: true } }),
      'EL CLIENTE PREGUNTA POR MLC'
    ) as string;
    expect(n).toContain('una persona del equipo le confirma la tasa por aqui');
    expect(dictadas([n])).toEqual([]);
  });
});

// Owner 2026-10-28: bring back verifying a deposit from a written TransID (312) on the live bot.
// `Liberar chat` already answers `verificar_transid` through cerebro_verificar_transid.
describe('verificar un deposito por TransID escrito (admin)', () => {
  const ruta = (texto: string, es_admin: boolean) =>
    correr({
      ctx: { es_admin },
      snapshot: { texto_completo: texto },
    }) as unknown as {
      ruta?: string;
      comando?: string;
      objetivo?: string;
    };

  it('un numero suelto de 14 digitos es un TransID', () => {
    const out = ruta('10404033303182', true);
    expect(out.ruta).toBe('comando');
    expect(out.comando).toBe('verificar_transid');
    expect(out.objetivo).toBe('10404033303182');
  });

  it('"verifica 10404033303182" y "transid: 10404033303182" tambien', () => {
    for (const t of ['verifica 10404033303182', 'transid: 10404033303182']) {
      const out = ruta(t, true);
      expect(out.comando, t).toBe('verificar_transid');
      expect(out.objetivo, t).toBe('10404033303182');
    }
  });

  it('"liberar <numero>" sigue siendo liberar', () => {
    expect(ruta('liberar 5926762167', true).comando).toBe('liberar');
  });

  it('a un cliente no le convierte el numero en comando', () => {
    expect(ruta('10404033303182', false).comando).not.toBe('verificar_transid');
  });
});

describe('fase 2 formato: invitacion al grupo, una sola vez a un cliente nuevo', () => {
  const PREFIJO = 'INVITACION AL GRUPO';
  const TEXTO =
    'Tenemos un grupo de WhatsApp de *Remesas Ya* donde compartimos tasas, promociones y avisos. Puede unirse aquí:';
  const ENLACE = 'https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81';

  it('cliente nuevo y grupo no enviado: dicta el texto literal, en usted, al final', () => {
    const out = correr({
      ctx: { grupo_enviado: false },
      historial: { envios_previos: 0 },
    });
    // The harness keeps only the first line of a note, so read the whole message.
    const n = out.mensaje as string;
    expect(nota(out, PREFIJO)).toBeDefined();
    expect(n).toContain(TEXTO + '\n' + ENLACE);
    expect(n).toMatch(/al FINAL/);
    expect(n).toMatch(/UNA sola vez/);
    expect(n).not.toMatch(/[Úú]nete/);
  });

  it('sin historial de envios tambien es cliente nuevo', () => {
    expect(
      nota(correr({ ctx: { grupo_enviado: false } }), PREFIJO)
    ).toBeDefined();
  });

  it('si el enlace ya se envio antes, no vuelve a salir', () => {
    expect(
      nota(correr({ ctx: { grupo_enviado: true } }), PREFIJO)
    ).toBeUndefined();
  });

  it('si falta el campo grupo_enviado, no se envia (falla cerrado)', () => {
    expect(nota(correr({}), PREFIJO)).toBeUndefined();
    expect(
      nota(correr({ ctx: { grupo_enviado: null } }), PREFIJO)
    ).toBeUndefined();
  });

  it('cliente con envios previos no recibe la invitacion', () => {
    expect(
      nota(
        correr({
          ctx: { grupo_enviado: false },
          historial: { envios_previos: 3 },
        }),
        PREFIJO
      )
    ).toBeUndefined();
  });

  it('un admin nunca la recibe', () => {
    const out = correr({ ctx: { grupo_enviado: false, es_admin: true } });
    expect(nota(out, PREFIJO)).toBeUndefined();
    expect(JSON.stringify(out)).not.toContain('chat.whatsapp.com');
  });
});

describe('fase 2 formato: "X pesos" sin apellido son GYD depositados', () => {
  const PESOS = 'El cliente dijo "X pesos" sin apellido';
  const cal = (texto: string) =>
    nota(correr({ snapshot: { texto_completo: texto } }), 'CALCULO A HACER');

  it('"cuanto llega con 5 mil pesos": GYD, minimo 5,000, sin preguntar CUP vs GYD', () => {
    const n = cal('cuanto le llega si deposito 5 mil pesos') as string;
    expect(n).toContain(PESOS);
    expect(n).toContain('5,000 GYD');
    expect(n).toContain('NO preguntes CUP vs GYD');
  });

  it('"quiero enviar 5 mil pesos" sin pregunta: cotiza por la tarjeta en CUP', () => {
    const n = cal('quiero enviar 5 mil pesos') as string;
    expect(n).toContain(PESOS);
    expect(n).toContain('calcular_envio');
  });

  it('con apellido ("cubanos" o "guyaneses") no se aplica', () => {
    expect(cal('quiero enviar 5 mil pesos cubanos')).toBeUndefined();
    expect(
      cal('cuanto le llega si deposito 5 mil pesos guyaneses')
    ).not.toContain(PESOS);
  });

  it('para que lleguen X pesos (monto de destino) no se aplica', () => {
    const n = cal('para que lleguen 5 mil pesos') as string;
    expect(n).not.toContain(PESOS);
  });

  it('con otra via elegida (Zelle) no se aplica', () => {
    const n = nota(
      correr({
        ctx: { riel_operacion: 'zelle' },
        snapshot: { texto_completo: 'quiero enviar 5 mil pesos' },
      }),
      'CALCULO A HACER'
    );
    expect(n).toBeUndefined();
  });
});

describe('fase 2 formato: fuera de horario con deposito o transferencia exige la linea de horario', () => {
  const CERRADO = '2026-10-21T07:00:00Z'; // Wednesday 03:00 Guyana
  const DOMINGO = '2026-10-25T15:00:00Z'; // Sunday 11:00 Guyana
  const ABIERTO = '2026-10-21T15:00:00Z';
  const OBLIGA = 'tu respuesta DEBE incluir la linea del horario';
  const comp = { moneda: 'GYD', estado: 'OK', alertas: [] };

  function en(hora: string, e: Entradas) {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(hora));
    try {
      return nota(correr(e), 'FUERA DE HORARIO') as string;
    } finally {
      vi.useRealTimers();
    }
  }

  afterEach(() => {
    vi.useRealTimers();
  });

  it('cerrado con comprobante: la linea es obligatoria y nombra la frase', () => {
    const n = en(CERRADO, {
      snapshot: { texto_completo: 'ok', comprobante: comp },
    });
    expect(n).toContain(OBLIGA);
    expect(n).toContain(
      'queda registrado y se procesa a partir de las 8:00 am (hora de Guyana)'
    );
  });

  it('cerrado con envio listo para transferir o por verificar: obligatoria', () => {
    for (const etapa of ['Lista para transferir', 'Por verificar']) {
      expect(
        en(CERRADO, { historial: { etapa_envio_abierto: etapa } }),
        etapa
      ).toContain(OBLIGA);
    }
  });

  it('cerrado y el cliente habla de transferencia o deposito: obligatoria', () => {
    for (const t of [
      'cuando me hacen la transferencia',
      'ya hice el deposito',
    ]) {
      expect(en(CERRADO, { snapshot: { texto_completo: t } }), t).toContain(
        OBLIGA
      );
    }
  });

  it('domingo con deposito: obligatoria', () => {
    expect(
      en(DOMINGO, { snapshot: { texto_completo: 'ok', comprobante: comp } })
    ).toContain(OBLIGA);
  });

  it('dia cerrado entero con deposito: obligatoria', () => {
    const n = en(ABIERTO, {
      ctx: { cierre_especial: { hoy_motivo: 'por feriado' } },
      snapshot: { texto_completo: 'ok', comprobante: comp },
    });
    expect(n).toContain(OBLIGA);
  });

  it('cerrado sin deposito ni transferencia: se conserva el comportamiento', () => {
    const n = en(CERRADO, { snapshot: { texto_completo: 'hola, buenas' } });
    expect(n).not.toContain(OBLIGA);
  });
});

// Owner 2026-10-28 (phase 2): bold only for amounts and states. Confirmed data goes one per line
// ("Etiqueta: valor") without bold, so the notes must not ask for it in bold.
describe('datos confirmados: uno por linea y sin negrita', () => {
  const casos: Array<[string, Entradas, string]> = [
    [
      'tarjeta y celular sin registrar',
      {
        historial: { envios_abiertos: 1 },
        ctx: { beneficiarios_registrados: [] },
        snapshot: {
          texto_completo: 'ok',
          tarjeta: '9224069992922522',
          celular: '53821202',
        },
      },
      'TARJETA Y CELULAR DETECTADOS PERO NO REGISTRADOS',
    ],
    [
      'beneficiario ya registrado',
      {
        ctx: {
          beneficiarios_registrados: [
            {
              t: 'cuban_card',
              tarjeta: '9224069992922522',
              celular: '53821202',
            },
          ],
        },
        snapshot: {
          texto_completo: 'mi tarjeta y mi celular van aqui',
          tarjeta: '9224069992922522',
          celular: '53821202',
        },
      },
      'Beneficiario YA REGISTRADO',
    ],
    [
      'cuenta Zelle',
      {
        historial: { envios_abiertos: 1 },
        snapshot: {
          texto_completo: 'Maria Lopez maria@correo.com',
          datos_zelle: true,
          zelle_nombre: 'Maria Lopez',
          zelle_correo: 'maria@correo.com',
        },
      },
      'DATOS DE ZELLE DETECTADOS',
    ],
  ];
  for (const [nombre, entradas, prefijo] of casos) {
    it(nombre, () => {
      const n = nota(correr(entradas), prefijo) as string;
      expect(n).toBeDefined();
      expect(n).not.toMatch(/en \*negrita\*/);
      expect(n).toContain('sin negrita');
      expect(n).toMatch(/uno por linea/);
    });
  }
});

// Owner 2026-10-28 (real reply 14:46): the bot said "La cuenta Zelle nueva queda anotada" without
// showing it, and "Una vez hecha su remesa le notificamos" while the holder's name was missing.
// The notes now carry the exact lines to show, and forbid talking about the transfer while a
// datum is missing.
describe('confirmacion visible y sin promesa mientras falte un dato', () => {
  it('Zelle sin nombre: muestra el celular literal y prohibe hablar de la remesa', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: 'Esta es otra cuenta',
        datos_zelle: true,
        zelle_celular: '3467445535',
      },
    });
    expect(s.mensaje).toContain('Cuenta Zelle anotada:\nCelular: 3467445535');
    const n = nota(s, 'DATOS DE ZELLE DETECTADOS') as string;
    expect(n).toMatch(/FALTA EL NOMBRE/);
    expect(n).toMatch(/PROHIBIDO decir "una vez hecha su remesa"/);
  });

  it('Zelle completo: muestra nombre y cuenta y no lleva la prohibicion', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: 'Maria Lopez maria@correo.com',
        datos_zelle: true,
        zelle_nombre: 'Maria Lopez',
        zelle_correo: 'maria@correo.com',
      },
    });
    expect(s.mensaje).toContain(
      'Cuenta Zelle anotada:\nNombre: Maria Lopez\nCorreo: maria@correo.com'
    );
    expect(nota(s, 'DATOS DE ZELLE DETECTADOS') as string).not.toMatch(
      /FALTA EL NOMBRE/
    );
  });

  it('tarjeta y celular: lineas literales para confirmar', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      ctx: { beneficiarios_registrados: [] },
      snapshot: {
        texto_completo: 'ok',
        tarjeta: '9224069992922522',
        celular: '53821202',
      },
    });
    expect(s.mensaje).toContain('Tarjeta: 9224069992922522\nCelular: 53821202');
  });

  it('comprobante repetido listo para transferir sin destino: no promete la remesa', () => {
    const s = correr({
      ctx: { dup_etapa: 'Lista para transferir' },
      snapshot: {
        texto_completo: '',
        comprobante: { monto: 24900, moneda: 'GYD' },
        comprobante_duplicado: true,
      },
    });
    const n = nota(s, 'ESTE COMPROBANTE YA ESTABA REGISTRADO') as string;
    expect(n).toBeDefined();
    expect(n).not.toMatch(/que una vez hecha su remesa le notificamos/);
    expect(n).toMatch(/PROHIBIDO decir "una vez hecha su remesa"/);
  });
});

describe('envio en efectivo: no se pide tarjeta', () => {
  const base = {
    texto_completo: 'mi familiar es 53821202',
    celular: '53821202',
  };

  it('riel efectivo_usd con celular y sin beneficiario: nota de efectivo, sin notas de tarjeta', () => {
    const s = correr({
      ctx: { riel_operacion: 'efectivo_usd', beneficiarios_registrados: [] },
      snapshot: base,
    });
    expect(nota(s, 'ENTREGA EN EFECTIVO') as string).toMatch(
      /PROHIBIDO pedir tarjeta.*nombre completo, direccion exacta o foto del carnet/
    );
    expect(nota(s, 'Celular cubano detectado')).toBeUndefined();
    expect(s.notas.join('\n')).not.toContain('Falta la tarjeta');
    expect(nota(s, 'TODAVIA NO HAY BENEFICIARIO REGISTRADO')).toBeUndefined();
    expect(s.notas.join('\n')).not.toContain('llama gestionar_beneficiario');
  });

  it('riel cuban_card: sigue pidiendo la tarjeta', () => {
    const s = correr({
      ctx: { riel_operacion: 'cuban_card', beneficiarios_registrados: [] },
      snapshot: base,
    });
    expect(nota(s, 'Celular cubano detectado')).toBeDefined();
    expect(nota(s, 'TODAVIA NO HAY BENEFICIARIO REGISTRADO')).toBeDefined();
    expect(nota(s, 'ENTREGA EN EFECTIVO')).toBeUndefined();
  });

  it('sin riel: se comporta como antes', () => {
    const s = correr({
      ctx: { beneficiarios_registrados: [] },
      snapshot: base,
    });
    expect(nota(s, 'Celular cubano detectado')).toBeDefined();
    expect(nota(s, 'ENTREGA EN EFECTIVO')).toBeUndefined();
  });
});

describe('varias cuentas Zelle: no forzar una pareja nombre-cuenta', () => {
  const base = {
    texto_completo: 'YLT WHOLESALE FOODS LLC 954-425-3182',
    datos_zelle: true,
    zelle_correos: [] as string[],
    zelle_celulares: ['9544253182', '8132940493'],
    zelle_nombre: 'YLT WHOLESALE FOODS LLC',
    zelle_nombre_cuenta: '8132940493',
  };

  it('no empuja registrar_beneficiario_zelle y pide confirmar cada cuenta', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: { ...base, zelle_varios: true },
    });
    const n = nota(s, 'VARIAS CUENTAS ZELLE DETECTADAS') as string;
    expect(n).toBeDefined();
    expect(n).toContain('9544253182');
    expect(n).toContain('8132940493');
    expect(n).toMatch(/NO registres ninguna/);
    expect(nota(s, 'TOOL OBLIGATORIA') ?? '').not.toContain(
      'registrar_beneficiario_zelle'
    );
    expect(nota(s, 'DATOS DE ZELLE DETECTADOS')).toBeUndefined();
  });

  it('con una sola cuenta sigue ordenando la tool', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        ...base,
        zelle_celulares: ['9544253182'],
        zelle_nombre_cuenta: '9544253182',
      },
    });
    const tools = nota(s, 'TOOL OBLIGATORIA') as string;
    expect(tools).toContain('registrar_beneficiario_zelle');
    expect(tools).toContain('9544253182');
  });

  it('usa la cuenta atada al nombre, no el primer numero de la lista', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        ...base,
        zelle_celulares: ['8132940493'],
        zelle_nombre_cuenta: '9544253182',
      },
    });
    const tools = nota(s, 'TOOL OBLIGATORIA') as string;
    expect(tools).toContain('9544253182');
    expect(tools).not.toContain('8132940493');
  });
});

describe('Zelle mas CUP en el mismo envio', () => {
  it('no dice que no hay CUP ni prohibe pedir la tarjeta', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: '100 dolares por zelle y el resto en tarjeta',
        datos_zelle: true,
        zelle_celulares: ['9544253182'],
        zelle_nombre: 'YLT WHOLESALE FOODS LLC',
        zelle_nombre_cuenta: '9544253182',
      },
    });
    const n = nota(s, 'DATOS DE ZELLE DETECTADOS') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/ADEMAS el resto en CUP/);
    expect(n).not.toMatch(/PROHIBIDO pedirle tarjeta/);
  });

  it('Zelle solo sigue prohibiendo pedir tarjeta', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: 'mi zelle',
        datos_zelle: true,
        zelle_celulares: ['9544253182'],
        zelle_nombre: 'YLT WHOLESALE FOODS LLC',
        zelle_nombre_cuenta: '9544253182',
      },
    });
    expect(nota(s, 'DATOS DE ZELLE DETECTADOS') as string).toMatch(
      /PROHIBIDO pedirle tarjeta/
    );
  });
});

describe('Zelle parcial y lista para transferir', () => {
  const zelle = {
    datos_zelle: true,
    zelle_celulares: ['9544253182'],
    zelle_nombre: 'YLT WHOLESALE FOODS LLC',
    zelle_nombre_cuenta: '9544253182',
  };
  const ctxZelle = (monto: number) => ({
    mensajes_cliente: 2,
    monto_recibe_valor: 100,
    monto_recibe_moneda: 'USD',
    tiene_beneficiario: true,
    beneficiarios_registrados: [
      {
        t: 'zelle',
        nombre: 'YLT WHOLESALE FOODS LLC',
        cuenta: '9544253182',
        monto,
        moneda: 'USD',
      },
    ],
  });

  it('con 50 de 100 USD asignados avisa que faltan 50 y no da por completo', () => {
    const s = correr({
      ctx: ctxZelle(50),
      snapshot: { texto_completo: 'A esta cuenta 50 dólares', ...zelle },
    });
    const n = nota(s, 'FALTAN') as string;
    expect(n).toBeDefined();
    expect(n).toContain('50 USD');
    expect(n).toMatch(/NO digas que esta completo/);
  });

  it('con 100 de 100 USD asignados no avisa de faltantes', () => {
    const s = correr({
      ctx: ctxZelle(100),
      snapshot: { texto_completo: 'hola', ...zelle },
    });
    expect(nota(s, 'FALTAN')).toBeUndefined();
  });

  it('lista para transferir no promete "enseguida"', () => {
    const s = correr({
      ctx: { mensajes_cliente: 2, tiene_beneficiario: true },
      historial: { etapa_envio_abierto: 'Lista para transferir' },
      snapshot: { texto_completo: 'como va lo mio' },
    });
    const n = nota(s, 'ESTADO REAL DEL ENVIO EN CURSO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/operador/);
    expect(n).not.toMatch(/enseguida/);
  });
});

describe('deposito que cubre un reparto planificado y confirmacion repetida', () => {
  it('un deposito que coincide con las partes no es "mando mas" ni incidencia', () => {
    const s = correr({
      snapshot: {
        texto_completo: 'Listo ahí le deposite',
        comprobante: {
          estado: 'LEGIBLE',
          monto: 26000,
          moneda: 'GYD',
          referencia: '20404215436140',
          alertas: [],
        },
      },
      mmg: {
        resultado: 'verificado_de_mas',
        objetivo: 13000,
        depositado: 26000,
        saldo: 13000,
      },
      ctx: {
        servicio_resuelto: {
          en_curso: 'cuban_card',
          reparto_pendiente: {
            deposito_gyd: 26000,
            partes: [
              { servicio: 'cuban_card', monto_gyd: 13000 },
              { servicio: 'zelle', monto_gyd: 13000 },
            ],
          },
        },
      },
    });
    const n = nota(s, 'EL CLIENTE DEPOSITO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/NO es un deposito de mas/);
    expect(n).toMatch(/NO le digas que mando mas/);
    expect(n).toMatch(/repartir_envio/);
    expect(n).not.toMatch(/Incidencia y lo revisa/);
  });

  it('sin reparto planificado, el deposito de mas sigue siendo incidencia', () => {
    const s = correr({
      snapshot: {
        texto_completo: 'Listo ahí le deposite',
        comprobante: {
          estado: 'LEGIBLE',
          monto: 26000,
          moneda: 'GYD',
          referencia: '20404215436140',
          alertas: [],
        },
      },
      mmg: {
        resultado: 'verificado_de_mas',
        objetivo: 13000,
        depositado: 26000,
        saldo: 13000,
      },
    });
    expect(nota(s, 'EL CLIENTE DEPOSITO MAS') as string).toMatch(/Incidencia/);
  });

  it('si el cliente solo acusa recibo, no repite tarjeta ni celular', () => {
    const s = correr({
      snapshot: { texto_completo: 'perfecto' },
      beneficiario: {
        tarjeta_final: '9224069992922522',
        celular_final: '53821202',
      },
      ctx: {
        beneficiarios_registrados: [
          { t: 'cuban_card', tarjeta: '9224069992922522', celular: '53821202' },
        ],
      },
    });
    const n = nota(s, 'Beneficiario YA REGISTRADO') as string;
    expect(n).toBeDefined();
    expect(n).toMatch(/NO repitas tarjeta ni celular/);
    expect(n).not.toMatch(/OBLIGATORIO/);
  });

  it('"5 mil pesos" se cotiza como GYD sin preguntar CUP vs GYD', () => {
    const s = correr({
      snapshot: { texto_completo: 'cuanto le llega si envio 5 mil pesos?' },
    });
    const n = nota(s, 'CALCULO A HACER') as string;
    expect(n).toMatch(/NO preguntes CUP vs GYD/);
    expect(n).toMatch(/calcular_envio/);
  });
});

// Production incident 2026-11-05: a team member wrote the Zelle account where an overpayment had to be
// returned; the customer then sent an image with that same account; the bot registered it as the
// customer's beneficiary and opened a Zelle send. Data the team gave is never the customer's recipient.
describe('datos dados por el equipo no son un beneficiario del cliente', () => {
  const TELEFONO_EQUIPO = '(305) 555-0142';
  const NO_VISTO = (linea: string) =>
    ['Companero del equipo: ' + linea, 'Cliente: ok, gracias'].join('\n');
  const AVISO = 'ESOS DATOS LOS DIO EL EQUIPO';
  const PREGUNTA = 'No hay ningun envio abierto';
  const imagenZelle = (celular: string) => ({
    texto_completo: '',
    datos_zelle: true,
    zelle_nombre: 'Maria Lopez',
    zelle_nombre_cuenta: celular,
    zelle_celular: celular,
  });

  it('(a) el equipo escribio el mismo celular que leyo la imagen: no ordena registrar y avisa', () => {
    const s = correr({
      ctx: {
        conversacion_no_vista: NO_VISTO(
          'devolvemos el sobrante a Maria Lopez ' + TELEFONO_EQUIPO
        ),
        envios_abiertos: 1,
      },
      historial: { envios_abiertos: 1 },
      snapshot: imagenZelle('+13055550142'),
    });
    expect(s.mensaje).not.toContain('Llama registrar_beneficiario_zelle');
    expect(s.mensaje).not.toContain('TOOL OBLIGATORIA');
    expect(nota(s, 'DATOS DE ZELLE DETECTADOS')).toBeUndefined();
    expect(nota(s, 'TODAVIA NO HAY BENEFICIARIO')).toBeUndefined();
    const n = nota(s, AVISO) as string;
    expect(n).toContain('PROHIBIDO registrarlos');
    expect(n).toContain('Responde solo a lo que dice el cliente');
    expect(s.notas.filter((x) => x.startsWith(AVISO))).toHaveLength(1);
  });

  it('(a) el correo se compara en minusculas y la tarjeta sin espacios', () => {
    const correo = correr({
      ctx: { conversacion_no_vista: NO_VISTO('es Maria.Lopez@Correo.com') },
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: '',
        datos_zelle: true,
        zelle_nombre: 'Maria Lopez',
        zelle_correo: 'maria.lopez@correo.com',
      },
    });
    expect(nota(correo, AVISO)).toBeDefined();
    expect(correo.mensaje).not.toContain('registrar_beneficiario_zelle');
    const tarjeta = correr({
      ctx: {
        conversacion_no_vista: NO_VISTO(
          'tarjeta 9224 0699 9292 2522 y 5382 1202'
        ),
      },
      historial: { envios_abiertos: 1 },
      snapshot: {
        texto_completo: '',
        tarjeta: '9224069992922522',
        celular: '53821202',
      },
    });
    expect(nota(tarjeta, AVISO)).toBeDefined();
    expect(tarjeta.mensaje).not.toContain('gestionar_beneficiario EN ESTE');
  });

  it('(a) solo cuentan las lineas del equipo, no las del cliente', () => {
    const s = correr({
      ctx: {
        conversacion_no_vista: [
          'Companero del equipo: buenas tardes',
          'Cliente: mi cuenta es ' + TELEFONO_EQUIPO,
        ].join('\n'),
      },
      historial: { envios_abiertos: 1 },
      snapshot: imagenZelle('+13055550142'),
    });
    expect(nota(s, AVISO)).toBeUndefined();
    expect(s.mensaje).toContain('Llama registrar_beneficiario_zelle');
  });

  it('(b) el cliente da una cuenta Zelle nueva con un envio abierto: sin cambios', () => {
    const s = correr({
      historial: { envios_abiertos: 1 },
      snapshot: imagenZelle('+13055550142'),
    });
    expect(nota(s, AVISO)).toBeUndefined();
    expect(nota(s, PREGUNTA)).toBeUndefined();
    expect(s.mensaje).toContain('Llama registrar_beneficiario_zelle');
  });

  it('(c) sin envio abierto y sin pedir un envio: pregunta antes de registrar', () => {
    const s = correr({ snapshot: imagenZelle('+13055550142') });
    expect(s.mensaje).not.toContain('Llama registrar_beneficiario_zelle');
    expect(s.mensaje).not.toContain('TOOL OBLIGATORIA');
    expect(nota(s, 'TODAVIA NO HAY BENEFICIARIO')).toBeUndefined();
    const n = nota(s, PREGUNTA) as string;
    expect(n).toContain('pregunta si son para un envio nuevo');
  });

  it('(c) tarjeta y celular sin envio abierto ni peticion: pregunta antes de registrar', () => {
    const s = correr({
      ctx: { beneficiarios_registrados: [] },
      snapshot: {
        texto_completo: '',
        tarjeta: '9224069992922522',
        celular: '53821202',
      },
    });
    expect(
      nota(s, 'TARJETA Y CELULAR DETECTADOS PERO NO REGISTRADOS')
    ).toBeUndefined();
    expect(s.mensaje).not.toContain('gestionar_beneficiario EN ESTE');
    expect(nota(s, PREGUNTA)).toBeDefined();
  });

  it('(c) si el cliente pide un envio nuevo en este turno, registra como siempre', () => {
    const s = correr({
      snapshot: {
        ...imagenZelle('+13055550142'),
        texto_completo: 'quiero enviar por zelle a esta cuenta',
      },
    });
    expect(nota(s, PREGUNTA)).toBeUndefined();
    expect(s.mensaje).toContain('Llama registrar_beneficiario_zelle');
  });

  it('(d) el equipo escribio OTRA cuenta: el dato del cliente se registra como siempre', () => {
    const s = correr({
      ctx: {
        conversacion_no_vista: NO_VISTO('devolvemos a +1 (786) 555-0199'),
      },
      historial: { envios_abiertos: 1 },
      snapshot: imagenZelle('+13055550142'),
    });
    expect(nota(s, AVISO)).toBeUndefined();
    expect(s.mensaje).toContain('Llama registrar_beneficiario_zelle');
  });
});

// Owner 2026-11-07 (conversation review of 2026-11-06): the customer said "Buenos dias ... buenas tardes ya" at
// 14:19 Guyana and the bot answered "Buenos dias": it mirrored the FIRST greeting instead of the correction.
describe('saludo: se copia el ultimo saludo del cliente', () => {
  it('con una autocorreccion usa la franja corregida', () => {
    const s = correr({
      historial: { primer_del_dia: true },
      snapshot: { texto_completo: 'Buenos días, buenas tardes ya. Es para poner trece mil' },
    });
    const n = nota(s, 'PRIMER CONTACTO DEL DIA') as string;
    expect(n).toContain('"buenas tardes"');
    expect(n).not.toContain('"Buenos días"');
  });

  it('con un solo saludo lo sigue copiando', () => {
    const s = correr({
      historial: { primer_del_dia: true },
      snapshot: { texto_completo: 'Buenas noches, quiero enviar' },
    });
    expect(nota(s, 'PRIMER CONTACTO DEL DIA') as string).toContain('"Buenas noches"');
  });

  // Owner 2026-11-10 (exec 689460): "hola buen día" at 18:11 UTC got "buenas tardes" by the clock.
  it.each([
    ['hola buen día', '"buen día"'],
    ['Buen dia, una pregunta', '"Buen dia"'],
    ['buena tarde quiero enviar', '"buena tarde"'],
    ['Buena noche', '"Buena noche"'],
  ])('reconoce el singular: %s', (texto, esperado) => {
    const s = correr({ historial: { primer_del_dia: true }, snapshot: { texto_completo: texto } });
    expect(nota(s, 'PRIMER CONTACTO DEL DIA') as string).toContain(esperado);
  });

  it('con saludo singular ya presentado devuelve el saludo', () => {
    const s = correr({ historial: { primer_del_dia: false }, snapshot: { texto_completo: 'buen día, ya deposité' } });
    const n = nota(s, 'YA te presentaste hoy') as string;
    expect(n).toContain('DEVUELVELE EL SALUDO');
    expect(n).toContain('"buen día"');
  });
});

// Owner 2026-11-07: the customer resent the same Zelle contact card and the bot showed "Cuenta Zelle anotada"
// a second time a minute later. An account already registered in an earlier turn was already confirmed.
describe('Zelle ya anotada en un turno anterior: no se repite la confirmacion', () => {
  const yaRegistrada: Entradas = {
    historial: { envios_abiertos: 1 },
    ctx: { beneficiarios_registrados: [{ t: 'zelle', nombre: 'Maria Lopez', cuenta: '3051234567' }] },
    snapshot: {
      texto_completo: 'Maria Lopez 13051234567',
      datos_zelle: true,
      zelle_nombre: 'Maria Lopez',
      zelle_celular: '13051234567',
    },
  };

  it('no ordena mostrar otra vez las lineas de la cuenta', () => {
    const s = correr(yaRegistrada);
    expect(s.mensaje).not.toContain('Cuenta Zelle anotada:');
    const n = nota(s, 'DATOS DE ZELLE DETECTADOS') as string;
    expect(n).toMatch(/YA ESTABA ANOTADA/);
    expect(n).toMatch(/NO repitas/);
  });

  it('una cuenta nueva sigue mostrando sus lineas', () => {
    const s = correr({
      ...yaRegistrada,
      snapshot: { ...yaRegistrada.snapshot, texto_completo: 'Ana Perez 13059876543', zelle_nombre: 'Ana Perez', zelle_celular: '13059876543' },
    });
    expect(s.mensaje).toContain('Cuenta Zelle anotada:\nNombre: Ana Perez');
  });
});

// Owner 2026-11-07, root fix: with a VERIFIED deposit and a reparto the Decisor stops guessing per-card amounts from
// the customer's words (96d81952: "10.000 mas para ponerle 5 a cada tarjeta" became 10,000 GYD per card; f80a33a0:
// "15mil a cada una" became 45,000 GYD). It states what the database knows (ctx.reparto_cuadre, migration 359).
describe('reparto con deposito verificado: el Decisor dice lo que sabe la base, no adivina por tarjeta', () => {
  const slots = (montos: number[]) =>
    montos.map((monto, i) => ({
      t: 'multiple_distribution',
      posicion: i + 1,
      tarjeta: `92240699929225${20 + i}`,
      celular: `5382120${i + 2}`,
      monto,
    }));
  const minimos = { minimo_gyd_cup: 3000, minimo_gyd_usd: 10000 };
  const cuadre = (c: Record<string, unknown>) => ({
    op_id: 'op-prueba',
    base_gyd: 10000,
    total_cup: 36000,
    total_usd: 38,
    tarjetas: 2,
    suma_cup_equiv: 36000,
    asignado: [],
    estado: 'cuadra',
    diferencia_cup: 0,
    por_tarjeta_igual_cup: 18000,
    ...c,
  });
  const caso96d81952 = (c: Record<string, unknown> = {}): Entradas => ({
    ctx: {
      minimos,
      beneficiarios_registrados: slots([36000, 36000]),
      reparto_cuadre: cuadre({ estado: 'excede', suma_cup_equiv: 72000, diferencia_cup: -36000, ...c }),
    },
    snapshot: { texto_completo: '10.000 más para ponerle 5 a cada tarjeta' },
  });
  const MONTO_GYD = 'MONTO EN GYD PARA EL REPARTO';

  it('96d81952 (excede): no adivina 10,000 GYD por tarjeta; da el total del deposito y manda preguntar', () => {
    const s = correr(caso96d81952());
    expect(nota(s, MONTO_GYD)).toBeUndefined();
    const n = nota(s, 'REPARTO Y DEPOSITO') as string;
    expect(n).toBeDefined();
    expect(n).toContain('el deposito verificado es 10,000 GYD = 36,000 CUP (o 38 USD en tarjeta Clasica/Tropical)');
    expect(n).toContain('Entre 2 tarjetas a partes iguales serian 18,000 CUP cada una.');
    expect(n).toContain('Los montos guardados suman mas que el deposito: PREGUNTA al cliente como repartir ese total; no confirmes montos.');
    expect(n).not.toMatch(/Sobran|Quedan/);
  });

  it('con montos escritos avisa que deben caber en el deposito y que la herramienta rechaza lo que pase', () => {
    const n = nota(correr(caso96d81952()), 'REPARTO Y DEPOSITO') as string;
    expect(n).toMatch(/monto sin moneda tiene que caber en el total del deposito \(36,000 CUP\)/);
    expect(n).toMatch(/registrar_reparto_multiple rechaza lo que pase de ahi/);
    expect(n).toMatch(/PREGUNTA, no inventes montos por tarjeta en GYD/);
  });

  it('sin montos en el mensaje no repite el aviso de montos', () => {
    const e = caso96d81952();
    e.snapshot = { texto_completo: 'gracias' };
    const n = nota(correr(e), 'REPARTO Y DEPOSITO') as string;
    expect(n).toBeDefined();
    expect(n).not.toMatch(/monto sin moneda/);
  });

  it('f80a33a0 (sobra 9000): dice cuanto sobra y pide repartir todo el deposito', () => {
    const s = correr({
      ctx: {
        minimos,
        beneficiarios_registrados: slots([15000, 15000, 15000]),
        reparto_cuadre: cuadre({
          base_gyd: 15000,
          total_cup: 54000,
          total_usd: 57,
          tarjetas: 3,
          suma_cup_equiv: 45000,
          estado: 'sobra',
          diferencia_cup: 9000,
        }),
      },
      snapshot: { texto_completo: 'Son 3 tarjetas 15mil a cada una' },
    });
    expect(nota(s, MONTO_GYD)).toBeUndefined();
    const n = nota(s, 'REPARTO Y DEPOSITO') as string;
    expect(n).toContain('el deposito verificado es 15,000 GYD = 54,000 CUP');
    expect(n).toContain('Entre 3 tarjetas a partes iguales serian 18,000 CUP cada una.');
    expect(n).toContain('Sobran 9,000 CUP: pide al cliente que reparta todo el deposito o que diga que hacer con ese monto.');
  });

  it('faltan_montos: dice cuantos CUP quedan por asignar', () => {
    const e = caso96d81952({ estado: 'faltan_montos', suma_cup_equiv: 18000, diferencia_cup: 18000 });
    const n = nota(correr(e), 'REPARTO Y DEPOSITO') as string;
    expect(n).toContain('Quedan 18,000 CUP por asignar.');
    expect(n).not.toMatch(/Sobran|suman mas/);
  });

  it('cuadra: solo los hechos del deposito, sin instruccion extra', () => {
    const e = caso96d81952({ estado: 'cuadra', suma_cup_equiv: 36000, diferencia_cup: 0 });
    e.snapshot = { texto_completo: 'gracias' };
    const n = nota(correr(e), 'REPARTO Y DEPOSITO') as string;
    expect(n).toBeDefined();
    expect(n).not.toMatch(/Sobran|Quedan|suman mas|PREGUNTA/);
  });

  it('sin ctx.reparto_cuadre (Contexto viejo o deposito sin verificar): conserva la nota anterior', () => {
    const e = caso96d81952();
    delete (e.ctx as Record<string, unknown>).reparto_cuadre;
    const s = correr(e);
    expect(nota(s, 'REPARTO Y DEPOSITO')).toBeUndefined();
    expect(nota(s, MONTO_GYD)).toBeDefined();
  });
});
