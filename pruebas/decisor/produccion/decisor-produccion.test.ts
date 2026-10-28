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
