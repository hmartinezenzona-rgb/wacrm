import { describe, expect, it } from 'vitest';

import { parseWhatsAppText } from './format';

describe('parseWhatsAppText', () => {
  it('marca la negrita de WhatsApp', () => {
    expect(parseWhatsAppText('Su depósito de *26,000 GYD* quedó verificado')).toEqual([
      { type: 'text', text: 'Su depósito de ' },
      { type: 'bold', text: '26,000 GYD' },
      { type: 'text', text: ' quedó verificado' },
    ]);
  });

  it('cursiva y tachado', () => {
    expect(parseWhatsAppText('_hola_ y ~adios~')).toEqual([
      { type: 'italic', text: 'hola' },
      { type: 'text', text: ' y ' },
      { type: 'strike', text: 'adios' },
    ]);
  });

  it('deja literal un marcador vacío o sin pareja', () => {
    expect(parseWhatsAppText('** vacío y *suelto')).toEqual([
      { type: 'text', text: '** vacío y *suelto' },
    ]);
  });

  it('no cruza saltos de línea', () => {
    expect(parseWhatsAppText('*uno\ndos*')).toEqual([{ type: 'text', text: '*uno\ndos*' }]);
  });
});
