import { describe, expect, it } from 'vitest';

import { MAX_SIDE, scaledSize } from './compress-image';

describe('scaledSize', () => {
  it('keeps a small image as it is', () => {
    expect(scaledSize(800, 600)).toEqual({ width: 800, height: 600 });
  });

  it('shrinks a landscape photo by its long side', () => {
    expect(scaledSize(4000, 3000)).toEqual({ width: 1600, height: 1200 });
  });

  it('shrinks a portrait capture by its long side', () => {
    expect(scaledSize(1080, 2400)).toEqual({ width: 720, height: 1600 });
  });

  it('never returns a zero side', () => {
    expect(scaledSize(10000, 1)).toEqual({ width: MAX_SIDE, height: 1 });
  });

  it('treats a broken size as unusable', () => {
    expect(scaledSize(0, 0)).toEqual({ width: 0, height: 0 });
    expect(scaledSize(Number.NaN, 100)).toEqual({ width: 0, height: 0 });
  });
});
