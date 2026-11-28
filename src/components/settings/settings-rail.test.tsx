// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NextIntlClientProvider } from 'next-intl';

import es from '../../../messages/es.json';

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const authMock = vi.hoisted(() => ({ value: {} as Record<string, unknown> }));
vi.mock('@/hooks/use-auth', () => ({ useAuth: () => authMock.value }));

import { SettingsRail } from './settings-rail';

function roleState(role: 'owner' | 'admin' | 'agent' | 'viewer') {
  const adminOrAbove = role === 'owner' || role === 'admin';
  return {
    accountRole: role,
    isOwner: role === 'owner',
    isAdmin: role === 'admin',
    canManageMembers: adminOrAbove,
    canEditSettings: adminOrAbove,
  };
}

describe('SettingsRail closed-days entry', () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    // jsdom has no matchMedia; the rail reads it to decide whether to auto-scroll.
    window.matchMedia = ((query: string) => ({
      matches: true,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    })) as unknown as typeof window.matchMedia;
    container = document.createElement('div');
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
  });

  function render() {
    act(() => {
      root.render(
        <NextIntlClientProvider locale="es" messages={es}>
          <SettingsRail active="overview" onSelect={() => {}} />
        </NextIntlClientProvider>
      );
    });
  }

  const label = (es as { Settings: { sections: Record<string, string> } })
    .Settings.sections['closed-days'];

  it('shows the closed-days section to the owner (admin or above, not only role admin)', () => {
    authMock.value = roleState('owner');
    render();
    expect(container.textContent).toContain(label);
  });

  it('shows it to an admin', () => {
    authMock.value = roleState('admin');
    render();
    expect(container.textContent).toContain(label);
  });

  it('hides it from an agent', () => {
    authMock.value = roleState('agent');
    render();
    expect(container.textContent).not.toContain(label);
  });
});
