import { describe, expect, it } from 'vitest';
import { formatPhoneForDisplay } from './phone-utils';

describe('formatPhoneForDisplay', () => {
  it('marks a bare stored number as international', () => {
    expect(formatPhoneForDisplay('529622896918')).toBe('+529622896918');
  });

  it('leaves an already-punctuated number untouched', () => {
    expect(formatPhoneForDisplay('+370 63949836')).toBe('+370 63949836');
    expect(formatPhoneForDisplay('(415) 555-0123')).toBe('(415) 555-0123');
  });

  it('does not touch something that is not a phone-length digit run', () => {
    expect(formatPhoneForDisplay('12345')).toBe('12345');
  });

  it('returns an empty string for missing values', () => {
    expect(formatPhoneForDisplay(null)).toBe('');
    expect(formatPhoneForDisplay('  ')).toBe('');
  });
});
