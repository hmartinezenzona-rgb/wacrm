// Tests for the notifier's customer messages. Owner, 2026-10-28: "cuando sea saldo o recarga no diga remesa sino
// su servicio como tal".
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { filtrar, FILTRAR_MD5_ESPERADO, ORIGEN_FILTRAR } from './correr';

const LEER_SECRETO_SQL = readFileSync(new URL('./leer-secreto.sql', import.meta.url), 'utf8');

const op = (service_type: string, status: string, extra: Record<string, unknown> = {}) => ({
  id: '00000000-0000-4000-8000-000000000001',
  conversation_id: '00000000-0000-4000-8000-000000000002',
  service_type,
  status,
  ...extra,
});

const completar = (service_type: string, extra: Record<string, unknown> = {}) =>
  filtrar(op(service_type, 'completed', extra), op(service_type, 'ready_to_transfer', extra));

const verificar = (service_type: string, beneficiarios: unknown[], extra: Record<string, unknown> = {}) =>
  filtrar(op(service_type, 'ready_to_transfer', extra), op(service_type, 'deposit_verification', extra), {
    verificacion_manual: true,
    beneficiarios,
  });

describe('la copia del nodo no puede derivar en silencio', () => {
  it('mantiene la huella del nodo', () => {
    const md5 = createHash('md5').update(readFileSync(ORIGEN_FILTRAR)).digest('hex');
    expect(md5).toBe(FILTRAR_MD5_ESPERADO);
  });
});

describe('aviso de completada: dice el servicio, no "remesa"', () => {
  it('saldo movil', () => {
    const [s] = completar('saldo');
    expect(s.json.mensaje).toBe('Listo, su saldo móvil{RECIBE} ya fue enviado. Gracias por confiar en *Remesas Ya*.');
    expect(s.json.mensaje).not.toMatch(/\bremesa\b/i);
  });

  it('recarga', () => {
    const [s] = completar('recarga');
    expect(s.json.mensaje).toBe('Listo, su recarga{RECIBE} ya fue realizada. Gracias por confiar en *Remesas Ya*.');
  });

  it('la remesa sigue igual', () => {
    const [s] = completar('remesa', { delivery_method: 'zelle' });
    expect(s.json.mensaje).toBe('Listo, su remesa{RECIBE} ya fue completada. Gracias por confiar en *Remesas Ya*.');
  });

  it('la plantilla de Meta, que dice "su remesa", solo va con una remesa', () => {
    expect(completar('remesa', { delivery_method: 'zelle' })[0].json.plantilla?.name).toBe('remesa_completada');
    for (const servicio of ['saldo', 'recarga', 'combo', 'visa']) {
      expect(completar(servicio)[0].json.plantilla, servicio).toBeUndefined();
    }
  });
});

describe('aviso de deposito verificado: dice el servicio, no "remesa"', () => {
  const numero = [{ beneficiary_type: 'recarga', phone: '5355555555' }];

  it('saldo movil con el numero dado', () => {
    const [s] = verificar('saldo', numero);
    expect(s.json.mensaje).toMatch(/su saldo móvil\{RECIBE\}|saldo móvil/);
    expect(s.json.mensaje).not.toMatch(/\bremesa\b|transferencia/i);
  });

  it('saldo movil sin el numero: pide el numero de Cuba, no una tarjeta', () => {
    const [s] = verificar('saldo', []);
    expect(s.json.mensaje).toMatch(/Para poder enviar su saldo móvil nos falta el numero de Cuba/);
    expect(s.json.mensaje).not.toMatch(/tarjeta|Zelle|transferencia/i);
  });

  it('recarga con el numero dado', () => {
    const [s] = verificar('recarga', numero);
    expect(s.json.mensaje).toMatch(/su recarga\{RECIBE\}/);
    expect(s.json.mensaje).not.toMatch(/\bremesa\b/i);
  });

  it('la remesa sigue hablando de su remesa', () => {
    const [s] = verificar('remesa', [{ beneficiary_type: 'zelle', name: 'X', zelle_account: '1' }], {
      delivery_method: 'zelle',
    });
    expect(s.json.mensaje).toMatch(/su remesa\{RECIBE\}/);
  });
});

describe('aviso de incidencia al admin: dice el motivo, no "Detalle: -"', () => {
  const incidencia = (incident_reason: string | null, extra: Record<string, unknown> = {}) =>
    filtrar(
      op('remesa', 'incident', { incident_reason, quoted_source_amount: 26000, source_currency: 'GYD' }),
      op('remesa', 'deposit_verification'),
      extra
    )[0].json as { destino?: string; alerta?: { detalle: string } };

  it('traduce sin_correo', () => {
    const s = incidencia('sin_correo');
    expect(s.destino).toBe('admin');
    expect(s.alerta?.detalle).toBe('El TransID del comprobante no aparece en ningun correo de MMG.');
  });

  it('traduce no_aplica', () => {
    expect(incidencia('no_aplica').alerta?.detalle).toBe(
      'El comprobante no se aplico: la operacion no estaba esperando un deposito.'
    );
  });

  it('un motivo escrito se pasa tal cual', () => {
    expect(incidencia('ALERTA: el TransID 10401606314994 ya fue usado en otro envio').alerta?.detalle).toBe(
      'ALERTA: el TransID 10401606314994 ya fue usado en otro envio'
    );
  });

  it('sin motivo usa las notas del deal si las hay', () => {
    expect(incidencia(null, { notas_deal: 'deposito de mas: 2,000 GYD' }).alerta?.detalle).toBe(
      'deposito de mas: 2,000 GYD'
    );
  });

  it('sin motivo ni notas lo dice claro, nunca "-"', () => {
    expect(incidencia(null).alerta?.detalle).toBe('El sistema no guardo el motivo: revise el chat.');
  });
});

describe('envio mixto: un solo aviso, al completarse la ultima parte', () => {
  // `grupo_pendientes` lo trae 'Leer secreto' (leer-secreto.sql): los OTROS miembros del grupo que no estan
  // cancelados ni completados, contados cuando corre el notificador. Sin grupo no hay `mixed_group_id`.
  const GRUPO = '00000000-0000-4000-8000-0000000000aa';
  const enGrupo = (service_type: string, grupo_pendientes: number | undefined, extra: Record<string, unknown> = {}) =>
    filtrar(
      op(service_type, 'completed', { mixed_group_id: GRUPO, ...extra }),
      op(service_type, 'ready_to_transfer', { mixed_group_id: GRUPO, ...extra }),
      grupo_pendientes === undefined ? {} : { grupo_pendientes }
    );
  const GENERAL = 'Listo, su envío ya fue completado. Gracias por confiar en *Remesas Ya*.';

  it('la primera parte en completarse no avisa al cliente', () => {
    expect(enGrupo('remesa', 1, { delivery_method: 'clasica' })).toEqual([]);
    expect(enGrupo('recarga', 2)).toEqual([]);
  });

  it('la ultima parte manda el aviso general, sin servicio, sin {RECIBE} y sin plantilla', () => {
    for (const servicio of ['remesa', 'recarga', 'saldo']) {
      const [s] = enGrupo(servicio, 0, { delivery_method: 'clasica' });
      expect(s.json.destino, servicio).toBe('cliente');
      expect(s.json.mensaje, servicio).toBe(GENERAL);
      expect(s.json.mensaje, servicio).not.toContain('{RECIBE}');
      expect(s.json.plantilla, servicio).toBeUndefined();
    }
  });

  it('sin grupo el aviso es el de siempre, aunque venga un conteo', () => {
    const [s] = filtrar(op('remesa', 'completed', { delivery_method: 'zelle' }), op('remesa', 'ready_to_transfer'), {
      grupo_pendientes: 3,
    });
    expect(s.json.mensaje).toBe('Listo, su remesa{RECIBE} ya fue completada. Gracias por confiar en *Remesas Ya*.');
    expect(s.json.plantilla?.name).toBe('remesa_completada');
    const [sinId] = filtrar(op('remesa', 'completed', { mixed_group_id: null }), op('remesa', 'ready_to_transfer'), {
      grupo_pendientes: 3,
    });
    expect(sinId.json.mensaje).toContain('su remesa{RECIBE}');
  });

  it('si no se sabe el estado del grupo, el aviso es el de siempre', () => {
    const [s] = enGrupo('remesa', undefined, { delivery_method: 'zelle' });
    expect(s.json.mensaje).toContain('su remesa{RECIBE}');
  });

  it('el silencio de siempre se mantiene dentro de un grupo', () => {
    const silenciada = filtrar(
      op('remesa', 'completed', { mixed_group_id: GRUPO, customer_notice_muted_for: 'completed' }),
      op('remesa', 'ready_to_transfer', { mixed_group_id: GRUPO }),
      { grupo_pendientes: 0 }
    );
    expect(silenciada).toEqual([]);
    const desdeIncidencia = filtrar(
      op('remesa', 'completed', { mixed_group_id: GRUPO }),
      op('remesa', 'incident', { mixed_group_id: GRUPO }),
      { grupo_pendientes: 0 }
    );
    expect(desdeIncidencia).toEqual([]);
  });

  it('las incidencias y la verificacion del deposito no cambian en un grupo', () => {
    const [verif] = filtrar(
      op('remesa', 'ready_to_transfer', { mixed_group_id: GRUPO, delivery_method: 'zelle' }),
      op('remesa', 'deposit_verification', { mixed_group_id: GRUPO }),
      { verificacion_manual: true, beneficiarios: [{ beneficiary_type: 'zelle', name: 'X', zelle_account: '1' }], grupo_pendientes: 1 }
    );
    expect(verif.json.mensaje).toMatch(/su remesa\{RECIBE\}/);
    const [inc] = filtrar(
      op('remesa', 'incident', { mixed_group_id: GRUPO, incident_reason: 'sin_correo' }),
      op('remesa', 'deposit_verification', { mixed_group_id: GRUPO }),
      { grupo_pendientes: 1 }
    );
    expect(inc.json.destino).toBe('admin');
  });
});

describe('leer-secreto.sql: el estado del grupo', () => {
  it('cuenta los otros miembros del grupo que no estan completados ni cancelados', () => {
    expect(LEER_SECRETO_SQL).toMatch(/AS grupo_pendientes/);
    expect(LEER_SECRETO_SQL).toMatch(/m\.mixed_group_id = /);
    expect(LEER_SECRETO_SQL).toMatch(/m\.id::text <> \$1/);
    expect(LEER_SECRETO_SQL).toMatch(/m\.status NOT IN \('completed', 'cancelled'\)/);
  });

  it('es una sola sentencia sin barra invertida (el nodo Postgres de n8n no los admite)', () => {
    expect(LEER_SECRETO_SQL).not.toContain(';');
    expect(LEER_SECRETO_SQL).not.toContain('\\');
  });
});
