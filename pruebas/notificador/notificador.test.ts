// Tests for the notifier's customer messages. Owner, 2026-10-28: "cuando sea saldo o recarga no diga remesa sino
// su servicio como tal".
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { filtrar, FILTRAR_MD5_ESPERADO, ORIGEN_FILTRAR } from './correr';

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
