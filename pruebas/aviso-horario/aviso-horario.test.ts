// Out-of-hours line appended by the `Normalizar formato` n8n node (2026-11-24).
// `aviso-horario.jscode` is the exact block inserted in that node on staging and
// production; this test runs it the same way n8n does, as plain function code.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

type Hechos = { horario?: string; presentacion?: string } | null;

const codigo = readFileSync(
  fileURLToPath(new URL('./aviso-horario.jscode', import.meta.url)),
  'utf8'
);

function cargar(hechosDecisor: Hechos) {
  const $ = () => ({ first: () => ({ json: { plan: { hechos: hechosDecisor } } }) });
  return new Function(
    '$',
    `${codigo}\nreturn { asegurarAvisoHorario, hechosDelDecisor, AVISO_FUERA_DE_HORARIO };`
  )($) as {
    asegurarAvisoHorario: (texto: string, hechos: Hechos) => string;
    hechosDelDecisor: () => Hechos;
    AVISO_FUERA_DE_HORARIO: string;
  };
}

const CERRADO = { horario: 'cerrado', presentacion: 'primer_contacto_del_dia' };

describe('aviso de fuera de horario', () => {
  const { asegurarAvisoHorario: aviso, AVISO_FUERA_DE_HORARIO: AVISO } = cargar(CERRADO);

  it('usa el texto elegido por el dueno', () => {
    expect(AVISO).toBe(
      'Ahora mismo estamos fuera de horario, pero puede dejarnos su solicitud y se la atendemos.'
    );
  });

  it('lo agrega cerrado y en el primer contacto del dia', () => {
    expect(aviso('Hola', CERRADO)).toBe(`Hola\n\n${AVISO}`);
  });

  it('no lo agrega abierto ni si ya se presento hoy', () => {
    expect(aviso('Hola', { ...CERRADO, horario: 'abierto' })).toBe('Hola');
    expect(aviso('Hola', { ...CERRADO, horario: 'proximo_a_cerrar' })).toBe('Hola');
    expect(aviso('Hola', { ...CERRADO, presentacion: 'ya_presentado' })).toBe('Hola');
  });

  it('no lo repite si el modelo ya lo dijo', () => {
    const t = 'Hoy no estamos trabajando por el aniversario.';
    expect(aviso(t, CERRADO)).toBe(t);
    expect(aviso('Estamos FUERA DE HORARIO.', CERRADO)).toBe('Estamos FUERA DE HORARIO.');
  });

  it('no toca SKIP, vacio ni falta de datos del Decisor', () => {
    expect(aviso('SKIP', CERRADO)).toBe('SKIP');
    expect(aviso('', CERRADO)).toBe('');
    expect(aviso('Hola', null)).toBe('Hola');
  });

  it('lee los hechos del plan del Decisor y tolera que falten', () => {
    expect(cargar(CERRADO).hechosDelDecisor()).toEqual(CERRADO);
    expect(cargar(null).hechosDelDecisor()).toBeNull();
  });
});
