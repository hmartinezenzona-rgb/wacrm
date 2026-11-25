// Días de la semana para personas: lunes primero, nombres completos y
// resúmenes legibles («Lunes a sábado», «Martes y jueves»).
// Los números son los de JavaScript y Postgres: 0 = domingo … 6 = sábado.

export const SEMANA: { n: number; corto: string; largo: string }[] = [
  { n: 1, corto: "Lun", largo: "lunes" },
  { n: 2, corto: "Mar", largo: "martes" },
  { n: 3, corto: "Mié", largo: "miércoles" },
  { n: 4, corto: "Jue", largo: "jueves" },
  { n: 5, corto: "Vie", largo: "viernes" },
  { n: 6, corto: "Sáb", largo: "sábado" },
  { n: 0, corto: "Dom", largo: "domingo" },
];

const MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

const cap = (s: string) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);

/** «Lunes a sábado», «Todos los días», «Martes y jueves», «Lunes, miércoles y viernes». */
export function resumenDias(dias: number[] | null | undefined): string {
  if (!dias) return "Todos los días";
  const orden = SEMANA.filter((d) => dias.includes(d.n));
  if (orden.length === 0) return "Ningún día";
  if (orden.length === 7) return "Todos los días";
  // Seguidos en la semana (lunes primero): «Lunes a viernes».
  const pos = orden.map((d) => SEMANA.indexOf(d));
  const seguidos = pos.every((p, i) => i === 0 || p === pos[i - 1] + 1);
  if (seguidos && orden.length >= 3) return `${cap(orden[0].largo)} a ${orden[orden.length - 1].largo}`;
  const nombres = orden.map((d) => d.largo);
  if (nombres.length === 1) return cap(nombres[0]);
  return cap(`${nombres.slice(0, -1).join(", ")} y ${nombres[nombres.length - 1]}`);
}

/** Fecha local AAAA-MM-DD (sin pasar por UTC). */
export function isoLocal(d: Date): string {
  const z = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  return z.toISOString().slice(0, 10);
}

/** «martes 24» */
export function diaCorto(iso: string): string {
  const d = new Date(iso + "T12:00:00");
  return `${SEMANA.find((x) => x.n === d.getDay())?.largo ?? ""} ${d.getDate()}`;
}

/** «martes 24 de nov» */
export function diaLargo(iso: string): string {
  const d = new Date(iso + "T12:00:00");
  return `${diaCorto(iso)} de ${MESES[d.getMonth()]}`;
}
