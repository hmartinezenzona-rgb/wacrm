import { describe, expect, it } from 'vitest';

import {
  MAX_IMAGE_BYTES,
  MAX_MESSAGES,
  cleanMessages,
  InvalidMessagesError,
} from './message-content';

const PNG_1PX =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

function userWithImage(url: string) {
  return [{ role: 'user', content: [{ type: 'text', text: 'mira' }, { type: 'image_url', image_url: { url } }] }];
}

describe('cleanMessages', () => {
  it('keeps plain text as before', () => {
    expect(cleanMessages([{ role: 'user', content: 'hola' }])).toEqual([
      { role: 'user', content: 'hola' },
    ]);
  });

  it('sends text and image as parts', () => {
    const [message] = cleanMessages(userWithImage(PNG_1PX));
    expect(message.role).toBe('user');
    expect(Array.isArray(message.content)).toBe(true);
    expect(message.content).toEqual([
      { type: 'text', text: 'mira' },
      { type: 'image_url', image_url: { url: PNG_1PX } },
    ]);
  });

  it('accepts a message with only an image', () => {
    const [message] = cleanMessages([
      { role: 'user', content: [{ type: 'image_url', image_url: { url: PNG_1PX } }] },
    ]);
    expect(Array.isArray(message.content)).toBe(true);
  });

  it('collapses a text-only partner list back to a string', () => {
    expect(
      cleanMessages([{ role: 'user', content: [{ type: 'text', text: 'una' }, { type: 'text', text: 'dos' }] }]),
    ).toEqual([{ role: 'user', content: 'una\ndos' }]);
  });

  it('refuses remote URLs', () => {
    expect(() => cleanMessages(userWithImage('https://evil.example/x.png'))).toThrow(
      InvalidMessagesError,
    );
  });

  it('refuses images in assistant turns', () => {
    expect(() =>
      cleanMessages([
        { role: 'assistant', content: [{ type: 'image_url', image_url: { url: PNG_1PX } }] },
      ]),
    ).toThrow(/usuario/);
  });

  it('refuses more than one image per message', () => {
    expect(() =>
      cleanMessages([
        {
          role: 'user',
          content: [
            { type: 'image_url', image_url: { url: PNG_1PX } },
            { type: 'image_url', image_url: { url: PNG_1PX } },
          ],
        },
      ]),
    ).toThrow(/una imagen/);
  });

  it('refuses an image over the byte cap', () => {
    // 4 base64 chars per 3 bytes; pad past the cap without allocating it.
    const big = `data:image/jpeg;base64,${'A'.repeat(Math.ceil((MAX_IMAGE_BYTES * 4) / 3) + 8)}`;
    expect(() => cleanMessages(userWithImage(big))).toThrow(/tamaño/);
  });

  it('refuses other content types', () => {
    expect(() =>
      cleanMessages([{ role: 'user', content: [{ type: 'file', file: {} }] }]),
    ).toThrow(InvalidMessagesError);
  });

  it('keeps only the last messages and caps the text', () => {
    const many = Array.from({ length: MAX_MESSAGES + 5 }, (_, i) => ({
      role: 'user' as const,
      content: `m${i} ${'x'.repeat(9000)}`,
    }));
    const cleaned = cleanMessages(many);
    expect(cleaned).toHaveLength(MAX_MESSAGES);
    expect(String(cleaned[0].content).length).toBe(8000);
  });
});
