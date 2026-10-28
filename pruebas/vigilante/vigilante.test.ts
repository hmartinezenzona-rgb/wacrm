// Tests for the Etecsa promo watcher's code nodes. Owner, 2026-10-28: a failed read of etecsa.cu must
// not count as a check (migration 349 reads `leida`), and the parser must keep reading real promos.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { buscar, MD5_ESPERADO, ORIGEN, parsear, type Item } from './correr';

const RECHAZADA: Item = {
  json: { error: { message: 'connect ECONNREFUSED 190.92.127.202:443', code: 'ECONNREFUSED' } },
};

// Wording of https://www.etecsa.cu/es/promocion/sextuplica/ilim, read on 2026-10-28.
const PAGINA_X6 =
  '<html><body><h1>PROMOCIÓN INTERNACIONAL DE RECARGA</h1>' +
  '<p>Esta promoción internacional consiste en que , del 29 al 31 de octubre de 2026 , cada cliente que ' +
  'reciba una recarga internacional desde nuestros distribuidores oficiales, entre 600 CUP y 1250 CUP, ' +
  '¡multiplicarán por 6 el monto de dinero recargado en su saldo principal!</p>' +
  '<p>El monto de dinero recargado ( multiplicado x 6 ) se añadirá directamente al saldo principal.</p>' +
  '</body></html>';

const HOME =
  '<a href="/es/promocion/oferta_internacional">a</a><a href="/es/promocion/sextuplica/ilim">b</a>' +
  '<a href="/es/promo/datos/24hs">c</a><a href="/themes/promo.css">d</a>';

describe('la copia de los nodos no puede derivar en silencio', () => {
  it.each(['buscar', 'parsear'] as const)('mantiene la huella de %s', (n) => {
    const md5 = createHash('md5').update(readFileSync(ORIGEN[n])).digest('hex');
    expect(md5).toBe(MD5_ESPERADO[n]);
  });
});

describe('Buscar candidatos', () => {
  it('marca la lectura fallida en vez de seguir como si no hubiera promos', () => {
    const [s] = buscar(RECHAZADA);
    expect(s.json).toMatchObject({ url: null, leida: false });
    expect(String(s.json.error)).toContain('ECONNREFUSED');
  });

  it('una home vacia tambien es una lectura fallida', () => {
    const [s] = buscar({ json: { data: '' } });
    expect(s.json).toMatchObject({ url: null, leida: false });
  });

  it('una home leida sin enlaces de promo es una revision buena', () => {
    const [s] = buscar({ json: { data: '<a href="/es/inicio">x</a>' } });
    expect(s.json).toMatchObject({ url: null, leida: true });
  });

  it('saca los enlaces de promo, sin hojas de estilo, con la URL completa', () => {
    const urls = buscar({ json: { data: HOME } }).map((i) => i.json.url);
    expect(urls).toEqual([
      'https://www.etecsa.cu/es/promocion/oferta_internacional',
      'https://www.etecsa.cu/es/promocion/sextuplica/ilim',
      'https://www.etecsa.cu/es/promo/datos/24hs',
    ]);
  });
});

describe('Parsear promocion', () => {
  const candidatos = buscar({ json: { data: HOME } });

  it('lee la promo real del 29 al 31 de octubre', () => {
    const [s] = parsear(
      [{ json: { data: '<p>Oferta de telefonos</p>' } }, { json: { data: PAGINA_X6 } }, { json: { data: '' } }],
      candidatos
    );
    expect(s.json).toMatchObject({
      ok: true,
      leida: true,
      min_cup: 600,
      max_cup: 1250,
      multiplicador: 6,
      desde: '2026-10-29',
      hasta: '2026-10-31',
      url: 'https://www.etecsa.cu/es/promocion/sextuplica/ilim',
    });
  });

  it('si la home no se pudo leer, lo dice (leida=false con el error)', () => {
    const sin = buscar(RECHAZADA);
    const [s] = parsear([{ json: { error: 'URL parameter must be a string, got null' } }], sin);
    expect(s.json).toMatchObject({ ok: false, leida: false });
    expect(String(s.json.error)).toContain('ECONNREFUSED');
  });

  it('si Etecsa corta una pagina de promo y ninguna se pudo leer, es lectura fallida', () => {
    const [s] = parsear(
      [{ json: { data: '<p>Oferta</p>' } }, RECHAZADA, { json: { data: '<p>datos</p>' } }],
      candidatos
    );
    expect(s.json).toMatchObject({ ok: false, leida: false });
    expect(String(s.json.error)).toContain('ECONNREFUSED');
  });

  it('un 404 de una pagina vieja no es un fallo de lectura', () => {
    const [s] = parsear(
      [
        { json: { data: '<p>Oferta</p>' } },
        { json: { error: { message: '404 - "Not Found"', httpCode: '404' } } },
        { json: { data: '<p>datos</p>' } },
      ],
      candidatos
    );
    expect(s.json).toEqual({ ok: false, leida: true });
  });

  it('sin promocion legible en paginas leidas: revision buena sin promo', () => {
    const [s] = parsear(
      [{ json: { data: '<p>Oferta</p>' } }, { json: { data: '<p>nada</p>' } }, { json: { data: '<p>x</p>' } }],
      candidatos
    );
    expect(s.json).toEqual({ ok: false, leida: true });
  });

  it('sin candidatos en una home leida: revision buena sin promo', () => {
    const sin = buscar({ json: { data: '<a href="/es/inicio">x</a>' } });
    const [s] = parsear([{ json: { error: 'URL parameter must be a string, got null' } }], sin);
    expect(s.json).toEqual({ ok: false, leida: true });
  });
});
