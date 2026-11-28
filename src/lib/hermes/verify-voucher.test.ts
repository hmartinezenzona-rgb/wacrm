import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { voucherSummary, verifyVoucher } from './verify-voucher';

const IMAGE = 'data:image/jpeg;base64,/9j/AAAA';
const VERDICT = {
  es_comprobante: true,
  tipo: 'comprobante',
  monto: 427500,
  moneda: 'GYD',
  referencia: '12345678901234',
  destinatario: 'Osmany Pozo',
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
  process.env.HERMES_VERIFICADOR_TOKEN = 'secreto';
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.HERMES_VERIFICADOR_URL;
  delete process.env.HERMES_VERIFICADOR_TOKEN;
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
      token: 'secreto',
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
  it('asks for the fixed block when the reference is in the ledger', () => {
    const text = voucherSummary(VERDICT as never);

    expect(text).toContain('Comprobante: en el libro de MMG');
    expect(text).toContain('Monto: 427,500 GYD');
    expect(text).toContain('Referencia: 12345678901234');
    expect(text).toContain('Destinatario: Osmany Pozo');
    expect(text).toContain('No añadas análisis del CRM');
  });

  it('says it does not figure in the ledger without claiming otherwise', () => {
    const text = voucherSummary({ ...VERDICT, en_libro: false } as never);

    expect(text).toContain('Comprobante: no figura en el libro de MMG');
  });

  it('asks for the original voucher when nothing could be read', () => {
    const text = voucherSummary({
      ...VERDICT,
      es_comprobante: false,
      tipo: 'otro',
      monto: null,
      referencia: null,
      en_libro: false,
    } as never);

    expect(text).toContain('Comprobante: no legible');
    expect(text).toContain('comprobante ORIGINAL de MMG');
  });
});
