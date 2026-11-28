// Pure validation for the away-mode routes (absence + closed days).

export const MOTIVO_MAX = 120;
export const MAX_DIAS_CERRADOS = 60;
const MIN_AHEAD_MS = 60_000;
const MAX_AHEAD_MS = 7 * 24 * 3600_000;

export type DiaCerrado = { fecha: string; motivo: string };

export type Validated<T> = ({ ok: true } & T) | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function cleanMotivo(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length >= 1 && trimmed.length <= MOTIVO_MAX ? trimmed : null;
}

/** True only for a real calendar date written as YYYY-MM-DD. */
export function isRealDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

export function validateAusenciaInput(
  body: unknown,
  now: Date = new Date(),
): Validated<{ hasta: string; motivo: string }> {
  if (!isRecord(body)) return { ok: false, error: "Cuerpo invalido" };
  if (typeof body.hasta !== "string") return { ok: false, error: "Falta la hora de regreso" };
  const hasta = new Date(body.hasta);
  if (Number.isNaN(hasta.getTime())) return { ok: false, error: "La hora de regreso no es valida" };
  const ahead = hasta.getTime() - now.getTime();
  if (ahead <= MIN_AHEAD_MS) return { ok: false, error: "La hora de regreso debe estar en el futuro" };
  if (ahead > MAX_AHEAD_MS) return { ok: false, error: "La hora de regreso no puede pasar de 7 dias" };
  const motivo = cleanMotivo(body.motivo);
  if (motivo === null) return { ok: false, error: `El motivo debe tener entre 1 y ${MOTIVO_MAX} caracteres` };
  return { ok: true, hasta: hasta.toISOString(), motivo };
}

function sortByFecha(dias: DiaCerrado[]): DiaCerrado[] {
  return [...dias].sort((a, b) => (a.fecha < b.fecha ? -1 : a.fecha > b.fecha ? 1 : 0));
}

export function validateDiasCerrados(body: unknown): Validated<{ dias: DiaCerrado[] }> {
  if (!isRecord(body) || !Array.isArray(body.dias)) return { ok: false, error: "Cuerpo invalido" };
  if (body.dias.length > MAX_DIAS_CERRADOS) {
    return { ok: false, error: `Maximo ${MAX_DIAS_CERRADOS} dias cerrados` };
  }
  const seen = new Set<string>();
  const dias: DiaCerrado[] = [];
  for (const item of body.dias) {
    if (!isRecord(item) || !isRealDate(item.fecha)) return { ok: false, error: "Fecha invalida" };
    if (seen.has(item.fecha)) return { ok: false, error: `Fecha repetida: ${item.fecha}` };
    seen.add(item.fecha);
    const motivo = cleanMotivo(item.motivo);
    if (motivo === null) {
      return { ok: false, error: `El motivo debe tener entre 1 y ${MOTIVO_MAX} caracteres` };
    }
    dias.push({ fecha: item.fecha, motivo });
  }
  return { ok: true, dias: sortByFecha(dias) };
}

/** Reads the stored config value; broken or unexpected content yields []. */
export function parseDiasCerrados(valor: string | null | undefined): DiaCerrado[] {
  if (!valor) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(valor);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const dias: DiaCerrado[] = [];
  for (const item of parsed) {
    if (isRecord(item) && isRealDate(item.fecha) && typeof item.motivo === "string") {
      dias.push({ fecha: item.fecha, motivo: item.motivo });
    }
  }
  return sortByFecha(dias);
}
