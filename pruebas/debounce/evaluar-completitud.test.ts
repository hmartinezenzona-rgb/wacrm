// Tests for the Cerebro adaptive debounce ("Evaluar completitud"). Owner, 2026-11-12: "si, hazlo también" (wait when the
// customer announces a destination without giving it; case 1727ef31, the account arrived 9 s after the batch was answered).
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { COMPLETITUD_MD5_ESPERADO, incompleto, ORIGEN_COMPLETITUD, type Evento } from './correr';

const t = (contenido: string): Evento => ({ tipo: 'text', contenido });
const img: Evento = { tipo: 'image' };

describe('la copia del nodo no puede derivar en silencio', () => {
  it('mantiene la huella del nodo', () => {
    const md5 = createHash('md5').update(readFileSync(ORIGEN_COMPLETITUD, 'utf8')).digest('hex');
    expect(md5.startsWith(COMPLETITUD_MD5_ESPERADO)).toBe(true);
  });
});

describe('lo que ya extendia sigue extendiendo', () => {
  it('anuncio de datos', () => {
    expect(incompleto([t('ahora te paso los datos')])).toBe(true);
    expect(incompleto([t('estos son:')])).toBe(true);
  });
  it('tarjeta sin celular', () => {
    expect(incompleto([t('9238 1234 3210 1987')])).toBe(true);
  });
  it('solo extiende una vez por ejecucion', () => {
    expect(incompleto([t('ahora te paso los datos')], 1)).toBe(false);
  });
});

describe('destino anunciado sin el dato', () => {
  it('el caso real: zelle a la cuenta, con el comprobante delante', () => {
    expect(incompleto([img, t('Pásame 58 zelle a la cuenta')])).toBe(true);
  });
  it('otros finales que anuncian el destino', () => {
    for (const s of ['mandalo a esta cuenta', 'ponlo a la tarjeta', 'envíalo al zelle', 'recarga a este número', 'a este numero']) {
      expect(incompleto([t(s)]), s).toBe(true);
    }
  });
  it('zelle pedido sin ninguna cuenta en el lote', () => {
    expect(incompleto([img, t('quiero mandar 100 por zelle')])).toBe(true);
  });
});

describe('lo completo no espera de mas', () => {
  it('zelle con correo o celular de EEUU', () => {
    expect(incompleto([t('Pásame 58 zelle a la cuenta'), t('juan.perez@example.com')])).toBe(false);
    expect(incompleto([t('58 zelle a la cuenta'), t('+1 (305) 555-0142')])).toBe(false);
    expect(incompleto([t('zelle 50 a la misma cuenta de la otra vez')])).toBe(false);
  });
  it('saludos, gracias y preguntas', () => {
    for (const s of ['Buenas tardes', 'gracias', 'Ok', '¿a cómo está la tasa?', 'ya hice el deposito a la cuenta que me diste']) {
      expect(incompleto([t(s)]), s).toBe(false);
    }
  });
});

describe('no espera de mas cuando no viene nada', () => {
  it('el cliente dice que los datos llegan despues (caso real 2026-11-13, exec 728308)', () => {
    expect(
      incompleto([t('quiero hacer dos recargas a estos números 53821204 , 53821205 y tmbn poner 50 zelle , en un rato le paso los datos y el depósito')])
    ).toBe(false);
    for (const s of ['quiero 100 por zelle, luego te mando la cuenta', 'mándalo a la cuenta, mañana te la paso', 'zelle 50, más tarde le paso los datos']) {
      expect(incompleto([t(s)]), s).toBe(false);
    }
  });
  it('los celulares de una recarga no son una tarjeta a medias', () => {
    expect(incompleto([t('recarga a estos numeros 53821204 y 53821205')])).toBe(false);
    expect(incompleto([t('ponle saldo al 53821204')])).toBe(false);
  });
  it('un celular suelto sin tarjeta sigue esperando la tarjeta', () => {
    expect(incompleto([t('53821204')])).toBe(true);
  });
  it('anunciar que viene YA sigue esperando', () => {
    expect(incompleto([t('quiero 100 por zelle, ahora te paso la cuenta')])).toBe(true);
  });
});

