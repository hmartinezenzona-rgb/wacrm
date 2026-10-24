import { describe, it, expect } from 'vitest';

import { GET } from './route';

describe('GET /grupo', () => {
  it('redirige a la invitación del grupo', () => {
    const res = GET();
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe(
      'https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81',
    );
  });
});
