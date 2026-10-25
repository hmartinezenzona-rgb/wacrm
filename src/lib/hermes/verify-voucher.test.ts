import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { voucherSummary, verifyVoucher } from './verify-voucher';

const IMAGE = 'data:image/jpeg;base64,/9j/AAAA';
const VERDICT = {
  es_comprobante: true,
  tipo: 'comprobante',
  monto: 427500,
  moneda: 'GYD',
  referencia: '12345678901234',
  banco_emisor: 'Banesco',
  fecha: '2026-10-25 00:00',
  en_libro: true,
  giro: 0,
  leida_girada: false,
  alertas: [],
  hash: 'abc123',
};

beforeEach(() => {
  process.env.HERMES_VERIFICADOR_URL = 'https://n8n.example/webhook/verificar-comprobante';
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.HERMES_VERIFICADOR_URL;
});

describe('verifyVoucher', () => {
  it('sends the image and returns the verdict', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify([VERDICT]), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const verdict = await verifyVoucher(IMAGE);

    expect(verdict?.en_libro).toBe(true);
    expect(verdict?.monto).toBe(427500);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://n8n.example/webhook/verificar-comprobante');
    expect(JSON.parse(String(init.body))).toEqual({
      imagen_base64: '/9j/AAAA',
      mime: 'image/jpeg',
    });
  });

  it('returns null without an endpoint', async () => {
    delete process.env.HERMES_VERIFICADOR_URL;
    vi.stubGlobal('fetch', vi.fn());
    await expect(verifyVoucher(IMAGE)).resolves.toBeNull();
  });

  it('returns null when the verifier fails', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('boom', { status: 500 })));
    await expect(verifyVoucher(IMAGE)).resolves.toBeNull();
  });

  it('returns null when the network throws', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('down')));
    await expect(verifyVoucher(IMAGE)).resolves.toBeNull();
  });

  it('returns null when the answer misses the verdict fields', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ hola: 1 }), { status: 200 })));
    await expect(verifyVoucher(IMAGE)).resolves.toBeNull();
  });
});

describe('voucherSummary', () => {
  it('states the ledger answer first and repeats the alerts', () => {
    const text = voucherSummary({
      ...VERDICT,
      es_comprobante: false,
      tipo: 'otro',
      monto: null,
      referencia: null,
      en_libro: false,
      alertas: ['SIN REFERENCIA LEGIBLE'],
    } as never);

    expect(text).toContain('¿Está en el libro de depósitos de MMG?: no');
    expect(text).toContain('lo clasificó como "otro"');
    expect(text).toContain('Monto leído: no legible');
    expect(text).toContain('Alertas: SIN REFERENCIA LEGIBLE');
  });
});
