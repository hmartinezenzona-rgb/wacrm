// Pure helpers for the away-mode popover. Guyana is UTC-4 all year (no DST),
// so a fixed offset is exact and independent of the browser's timezone.

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
const GUYANA_OFFSET_MS = -4 * HOUR_MS;

/** Guyana wall clock of an instant, read through the UTC getters. */
function wall(date: Date): Date {
  return new Date(date.getTime() + GUYANA_OFFSET_MS);
}

/** The instant at which Guyana's wall clock reads the given day and time. */
function atGuyana(dayWall: Date, hour: number, minute: number): Date {
  return new Date(
    Date.UTC(dayWall.getUTCFullYear(), dayWall.getUTCMonth(), dayWall.getUTCDate(), hour, minute) -
      GUYANA_OFFSET_MS,
  );
}

/** "Un rato": one hour from now. */
export function presetRato(now: Date): Date {
  return new Date(now.getTime() + HOUR_MS);
}

/**
 * "Hasta una hora": that HH:mm today in Guyana; tomorrow when it is not in
 * the future. Null when the text is not a valid 24-hour time.
 */
export function presetHastaHora(now: Date, hhmm: string): Date | null {
  const match = /^(\d{1,2}):(\d{2})$/.exec(hhmm.trim());
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour > 23 || minute > 59) return null;
  const today = atGuyana(wall(now), hour, minute);
  return today.getTime() > now.getTime() ? today : new Date(today.getTime() + DAY_MS);
}

/** "Resto del día": tomorrow 09:00 Guyana; Sunday is skipped to Monday. */
export function presetRestoDelDia(now: Date): Date {
  let target = atGuyana(wall(now), 9, 0);
  target = new Date(target.getTime() + DAY_MS);
  if (wall(target).getUTCDay() === 0) target = new Date(target.getTime() + DAY_MS);
  return target;
}

/** "3:00 pm" in Guyana time. */
export function formatHora(date: Date): string {
  const local = wall(date);
  const hour = local.getUTCHours();
  const minute = String(local.getUTCMinutes()).padStart(2, "0");
  const suffix = hour >= 12 ? "pm" : "am";
  return `${hour % 12 === 0 ? 12 : hour % 12}:${minute} ${suffix}`;
}

export interface ReturnDescription {
  day: "today" | "tomorrow" | "other";
  /** 0 = Sunday ... 6 = Saturday, in Guyana. */
  weekday: number;
  time: string;
}

/** Where `hasta` falls relative to `now` on the Guyana calendar. */
export function describeReturn(hasta: Date, now: Date): ReturnDescription {
  const dayIndex = (d: Date) => Math.floor(wall(d).getTime() / DAY_MS);
  const diff = dayIndex(hasta) - dayIndex(now);
  return {
    day: diff <= 0 ? "today" : diff === 1 ? "tomorrow" : "other",
    weekday: wall(hasta).getUTCDay(),
    time: formatHora(hasta),
  };
}

/** HH:mm of the next whole hour in Guyana: a sensible default for the time input. */
export function defaultHoraInput(now: Date): string {
  const next = new Date(wall(now).getTime() + HOUR_MS);
  return `${String(next.getUTCHours()).padStart(2, "0")}:00`;
}
