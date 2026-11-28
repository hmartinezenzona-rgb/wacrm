// Slice-4 review (BLOCKER): day labels were derived by re-parsing the local
// `yyyy-MM-dd` day key, and `new Date("yyyy-MM-dd")` is UTC midnight. In a
// UTC-negative zone that instant is the previous calendar day, so every
// separator and header read one day early ("Ayer" for today).
//
// This file must run under a non-UTC zone to prove the fix; a UTC-only test
// cannot see the off-by-one. `process.env.TZ` is set before any date work and
// restored afterwards so it cannot leak into other test files sharing the
// worker.

import { afterAll, describe, expect, it } from 'vitest';
import { format } from 'date-fns';
import { formatThreadDayLabel } from './thread-items';

const ORIGINAL_TZ = process.env.TZ;
process.env.TZ = 'America/Havana'; // UTC-5 (no DST in late November)

afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete process.env.TZ;
  else process.env.TZ = ORIGINAL_TZ;
});

const t = (key: 'today' | 'yesterday') => key;

describe('formatThreadDayLabel in America/Havana (UTC-5)', () => {
  it('labels a UTC instant that is still yesterday locally as "today"', () => {
    // 2026-11-27T02:00Z is 2026-11-26 21:00 in Havana.
    const now = new Date('2026-11-27T01:00:00Z'); // 2026-11-26 20:00 Havana
    expect(formatThreadDayLabel('2026-11-27T02:00:00Z', now, t)).toBe('today');
  });

  it('shows the previous-day label the old UTC-midnight parse produced', () => {
    // Reproduces the pre-fix path: format the local day key, re-parse it.
    const dayKey = format(new Date('2026-11-27T02:00:00Z'), 'yyyy-MM-dd'); // 2026-11-26
    const utcParsedKey = new Date(dayKey); // 2026-11-26T00:00Z = 11-25 19:00 Havana
    expect(utcParsedKey.getDate()).toBe(25);
    const now = new Date('2026-11-27T01:00:00Z'); // 11-26 20:00 Havana
    expect(formatThreadDayLabel(utcParsedKey, now, t)).toBe('yesterday');
  });

  it('labels the separator with the next local day, not that day minus one', () => {
    const now = new Date('2026-11-27T01:00:00Z'); // 2026-11-26 in Havana
    // 2026-11-27T06:00Z is 2026-11-27 01:00 in Havana (next local day).
    expect(formatThreadDayLabel('2026-11-27T06:00:00Z', now, t)).toBe(
      'November 27, 2026',
    );
  });
});
