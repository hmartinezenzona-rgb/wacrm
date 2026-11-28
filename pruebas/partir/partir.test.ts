// Tests for the `Partir respuesta` node (`./partir.jscode`): one customer reply becomes 1..4 WhatsApp
// messages, cut only on blank lines between blocks, never leaving an idea in halves.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import {
  correrNodo,
  ORIGEN_PARTIR,
  partir,
  PARTIR_MD5_ESPERADO,
} from './correr';
import { bloques, FIXTURES, partesEsperadas } from './fixtures';

const normalizado = (t: string) => bloques(t).join('\n\n');
const MARCA_LISTA = /^\s*(?:[-*•]\s+|\d+[.)]\s+)/;
const esLista = (b: string) => b.split('\n').every((l) => MARCA_LISTA.test(l));
const digitos = (t: string) => (t.match(/\d/g) ?? []).sort().join('');

describe('la copia del nodo no puede derivar en silencio', () => {
  it('mantiene la huella del nodo', () => {
    const md5 = createHash('md5')
      .update(readFileSync(ORIGEN_PARTIR))
      .digest('hex');
    expect(md5).toBe(PARTIR_MD5_ESPERADO);
  });
});

describe.each(FIXTURES)('$nombre', (f) => {
  const partes = partir(f.texto);

  it('parte exactamente en los bloques esperados', () => {
    expect(partes).toEqual(partesEsperadas(f));
  });

  it('no suelta texto: unidas con una linea en blanco dan el original normalizado', () => {
    expect(partes.join('\n\n')).toBe(normalizado(f.texto));
    expect(digitos(partes.join(''))).toBe(digitos(f.texto));
  });

  it('entre 1 y 4 mensajes, ninguno vacio', () => {
    expect(partes.length).toBeGreaterThanOrEqual(1);
    expect(partes.length).toBeLessThanOrEqual(4);
    for (const p of partes) expect(p.trim()).not.toBe('');
  });

  it('ningun mensaje termina en ":"', () => {
    for (const p of partes) expect(p.trimEnd().endsWith(':')).toBe(false);
  });

  it('ninguna lista queda partida de lo que la introduce', () => {
    const b = bloques(f.texto);
    const parteDe: number[] = [];
    partes.forEach((p, i) => p.split('\n\n').forEach(() => parteDe.push(i)));
    b.forEach((bloque, i) => {
      if (i > 0 && esLista(bloque)) expect(parteDe[i]).toBe(parteDe[i - 1]);
    });
  });
});

describe('falla cerrado a UN solo mensaje, tal como esta hoy', () => {
  const largo = (extra = '') =>
    `Su depósito de *12,000 GYD* ha sido verificado y está listo para enviar.${extra}\n\nSu remesa de *70 USD* se hace mañana a primera hora, a partir de las 9:00am.\n\n¿Todo bien?`;

  it('el caso base de este bloque si parte (control)', () => {
    expect(partir(largo())).toHaveLength(3);
  });

  it('un solo bloque', () => {
    const t =
      'Su depósito de *12,000 GYD* ha sido verificado.\nSu remesa de *70 USD* se hace mañana a primera hora, a partir de las 9:00am y una vez hecha le notificamos por acá.\n¿Todo bien?';
    expect(t.length).toBeGreaterThan(160);
    expect(partir(t)).toEqual([t]);
  });

  it('texto de menos de 160 caracteres', () => {
    const t =
      'Anotado, gracias por los datos.\n\nLe confirmo en un momento.\n\n¿Algo más?';
    expect(t.length).toBeLessThan(160);
    expect(partir(t)).toEqual([t]);
  });

  it('asterisco sin cerrar en cualquier bloque', () => {
    const t = largo().replace('*70 USD*', '*70 USD');
    expect(partir(t)).toEqual([t]);
  });

  it('SKIP', () => {
    expect(partir('SKIP')).toEqual(['SKIP']);
    const t = largo('\n\nSKIP');
    expect(partir(t)).toEqual([t]);
  });

  it('el texto termina en ":" (no hay siguiente bloque al que unirlo)', () => {
    const t = `${largo()}\n\nLe paso la cuenta:`;
    expect(partir(t)).toEqual([t]);
  });

  it('bandera apagada o ausente: exactamente el mensaje de hoy', () => {
    expect(partir(largo(), 'no')).toEqual([largo()]);
    expect(partir(largo(), '')).toEqual([largo()]);
    const sinBandera = correrNodo([{ json: { output: largo() } }]);
    expect(sinBandera[0].json.partes).toEqual([largo()]);
  });

  it('una excepcion no tumba el nodo: devuelve el item tal cual', () => {
    const item = {
      json: { output: 42 as unknown, opt_partir_respuesta: 'si' },
    };
    const salida = correrNodo([item]);
    expect(salida).toHaveLength(1);
    expect(salida[0].json.output).toBe(42);
  });
});

describe('reglas de union', () => {
  it('una frase corta que no es pregunta se une con la siguiente', () => {
    const t =
      'Anotado.\n\nSu depósito de *12,000 GYD* ha sido verificado y su envío de *70 USD* sale mañana a primera hora, a partir de las 9:00am.\n\n¿Todo correcto con los datos?';
    expect(partir(t)).toEqual([
      t.split('\n\n').slice(0, 2).join('\n\n'),
      '¿Todo correcto con los datos?',
    ]);
  });

  it('una pregunta corta puede quedar sola al final', () => {
    const p = partir(FIXTURES[1].texto);
    expect(p[p.length - 1]).toBe('¿Cuánto desea enviar?');
  });

  it('una frase corta al final se une con la anterior', () => {
    const p = partir(FIXTURES[9].texto);
    expect(p).toHaveLength(1);
    expect(p[0].endsWith('Las transferencias salen enseguida.')).toBe(true);
  });

  it('con muchos bloques nunca pasa de 4 mensajes y no pierde nada', () => {
    const b = Array.from(
      { length: 8 },
      (_, i) =>
        `Idea número ${i + 1}: el monto de *${i + 1}00 GYD* queda anotado en su cuenta.`
    );
    const t = `${b.join('\n\n')}\n\n¿Todo bien?`;
    const p = partir(t);
    expect(p.length).toBeLessThanOrEqual(4);
    expect(p.join('\n\n')).toBe(t);
    expect(p[p.length - 1]).toBe('¿Todo bien?');
  });

  it('normaliza corridas de lineas en blanco y espacios en las lineas vacias', () => {
    const t = FIXTURES[6].texto.replace(/\n\n/g, '\n \n\n\n');
    expect(partir(t).join('\n\n')).toBe(normalizado(FIXTURES[6].texto));
  });

  it('acepta saltos de linea de Windows', () => {
    const t = FIXTURES[6].texto.replace(/\n/g, '\r\n');
    expect(partir(t)).toEqual(partesEsperadas(FIXTURES[6]));
  });
});

describe('contrato del nodo', () => {
  it('devuelve un item por item de entrada, con partes y partes_n, sin perder campos', () => {
    const salida = correrNodo([
      {
        json: {
          output: FIXTURES[6].texto,
          opt_partir_respuesta: 'si',
          telefono_e164: '+5920000000',
        },
      },
    ]);
    expect(salida).toHaveLength(1);
    expect(salida[0].json.partes_n).toBe(4);
    expect(salida[0].json.partes).toHaveLength(4);
    expect(salida[0].json.telefono_e164).toBe('+5920000000');
    expect(salida[0].json.output).toBe(FIXTURES[6].texto);
  });
});
