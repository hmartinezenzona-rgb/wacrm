import { describe, it, expect, vi, beforeEach } from 'vitest';

const mocks = vi.hoisted(() => ({ leer: vi.fn() }));

vi.mock('@/lib/settings/group-link', () => ({
  leerGrupoUrl: mocks.leer,
}));

import { GET } from './route';

beforeEach(() => {
  mocks.leer.mockReset();
});

describe('GET /grupo', () => {
  it('redirige al enlace configurado', async () => {
    mocks.leer.mockResolvedValue('https://chat.whatsapp.com/OTROGRUPO');
    const res = await GET();
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('https://chat.whatsapp.com/OTROGRUPO');
  });

  it('sin configuración usa el enlace por defecto', async () => {
    mocks.leer.mockResolvedValue('https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81');
    const res = await GET();
    expect(res.headers.get('location')).toBe(
      'https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81',
    );
  });
});
