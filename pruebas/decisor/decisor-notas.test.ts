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

import { describe, expect, it } from 'vitest';

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
      ['comprobante', { snapshot: { texto_completo: 'ahi va el comprobante' } }],
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
