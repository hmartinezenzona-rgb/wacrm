// @vitest-environment jsdom
//
// A seeded page must paint its signed URL on the FIRST render: no null-then-src
// flash, and no sign request for media the page response already covered.

import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { resetSignedMediaCache, seedSignedMedia } from './signed-media';
import { useMediaSrc } from './use-media-src';

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

const ACCOUNT = 'account-465fb4ce-33b6-4473-ad2c-42818772f587';
const STORED = `https://x.supabase.co/storage/v1/object/public/chat-media/${ACCOUNT}/a.jpg`;
const STORED_B = `https://x.supabase.co/storage/v1/object/public/chat-media/${ACCOUNT}/b.jpg`;

function Harness({ url, onValue }: { url: string; onValue: (value: string | null) => void }) {
  onValue(useMediaSrc(url));
  return null;
}

async function render(url: string, onValue: (value: string | null) => void) {
  const node = document.createElement('div');
  const root = createRoot(node);
  await act(async () => {
    root.render(React.createElement(Harness, { url, onValue }));
  });
  return { root, unmount: () => act(async () => root.unmount()) };
}

beforeEach(() => {
  resetSignedMediaCache();
});

afterEach(() => {
  vi.unstubAllGlobals();
  resetSignedMediaCache();
});

describe('useMediaSrc', () => {
  it('returns a seeded URL on the first render', async () => {
    seedSignedMedia({ [STORED]: 'https://signed/a' }, 3600);
    const values: (string | null)[] = [];
    const { unmount } = await render(STORED, (value) => values.push(value));

    expect(values[0]).toBe('https://signed/a');
    await unmount();
  });

  it('does not sign a URL whose seeded entry is fresh', async () => {
    seedSignedMedia({ [STORED]: 'https://signed/a' }, 3600);
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const { unmount } = await render(STORED, () => {});

    expect(fetchMock).not.toHaveBeenCalled();
    await unmount();
  });

  it('still resolves an unseeded URL through the async path', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ signed: { [STORED]: 'https://signed/a' }, expiresIn: 3600 }),
    });
    vi.stubGlobal('fetch', fetchMock);

    const values: (string | null)[] = [];
    const { unmount } = await render(STORED, (value) => values.push(value));
    // Collecting the flush window is timer based; wait for the re-render.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 50));
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(values.at(-1)).toBe('https://signed/a');
    await unmount();
  });

  it('peeks the new seeded url synchronously when the media_url changes', async () => {
    seedSignedMedia({ [STORED]: 'https://signed/a', [STORED_B]: 'https://signed/b' }, 3600);
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);

    const first: (string | null)[] = [];
    const node = document.createElement('div');
    const root = createRoot(node);
    await act(async () => {
      root.render(React.createElement(Harness, { url: STORED, onValue: (v) => first.push(v) }));
    });
    expect(first.at(-1)).toBe('https://signed/a');

    const second: (string | null)[] = [];
    await act(async () => {
      root.render(React.createElement(Harness, { url: STORED_B, onValue: (v) => second.push(v) }));
    });

    // No null frame between the two urls, and no sign request.
    expect(second[0]).toBe('https://signed/b');
    expect(second).not.toContain(null);
    expect(fetchMock).not.toHaveBeenCalled();

    await act(async () => root.unmount());
  });
});
