// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import es from '../../../messages/es.json';
import { HermesChat } from './hermes-chat';

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock('next-intl', () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split('.')
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, es as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, string>) => {
      let text = key.split('.').reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      for (const [name, value] of Object.entries(params ?? {})) {
        text = text.replace(`{${name}}`, value);
      }
      return text;
    };
  },
}));

vi.mock('@/hooks/use-auth', () => ({
  useAuth: () => ({ profile: { full_name: 'Humbe Pérez' }, account: { name: 'Remesas Ya' } }),
}));

const STORAGE_KEY = 'wacrm.hermes.chat.v1';

async function mount() {
  const host = document.createElement('div');
  document.body.appendChild(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(<HermesChat />);
  });
  // The chat reads sessionStorage after mount.
  await act(async () => {
    await Promise.resolve();
  });
  return { host, root };
}

describe('HermesChat scroll position', () => {
  beforeEach(() => {
    sessionStorage.clear();
    Element.prototype.scrollIntoView = vi.fn();
    Element.prototype.scrollTo = vi.fn();
  });

  afterEach(() => {
    document.body.innerHTML = '';
    vi.restoreAllMocks();
  });

  it('shows the greeting and idea cards from the top, not scrolled to the composer', async () => {
    const { host } = await mount();

    expect(host.textContent).toContain('¿Qué revisamos hoy, Humbe?');
    expect(host.textContent).toContain('Remesas Ya');
    expect(Element.prototype.scrollIntoView).not.toHaveBeenCalled();
    // The approved layout asks first: the composer sits above the cards.
    const textarea = host.querySelector('textarea');
    const cards = host.querySelector('#hermes-ideas');
    expect(textarea).not.toBeNull();
    expect(cards).not.toBeNull();
    expect(cards!.compareDocumentPosition(textarea!) & Node.DOCUMENT_POSITION_PRECEDING).toBeTruthy();
  });

  it('scrolls to the last message when a saved conversation is restored', async () => {
    sessionStorage.setItem(
      STORAGE_KEY,
      JSON.stringify([
        { role: 'user', content: '¿Cuadra el día?' },
        { role: 'assistant', content: 'Sí, todo cuadra.' },
      ]),
    );
    const { host } = await mount();

    expect(host.textContent).toContain('Sí, todo cuadra.');
    expect(Element.prototype.scrollIntoView).toHaveBeenCalled();
  });
});
